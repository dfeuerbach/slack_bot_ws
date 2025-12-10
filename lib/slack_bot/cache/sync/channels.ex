defmodule SlackBot.Cache.Sync.Channels do
  @moduledoc false

  use GenServer

  require Logger

  alias SlackBot
  alias SlackBot.Cache
  alias SlackBot.Config
  alias SlackBot.ConfigServer
  alias SlackBot.Telemetry

  @type option :: {:name, GenServer.name()} | {:config_server, GenServer.server()}
  @type sync_count :: non_neg_integer()
  @type sync_result ::
          {:ok, sync_count()}
          | {:error, term(), sync_count()}
          | {:rate_limited, pos_integer(), String.t() | nil, sync_count()}

  @type pending_sync :: %{
          bot_user_id: String.t(),
          cursor: String.t() | nil,
          count: sync_count()
        }

  @type run_sync_result ::
          {:ok, String.t(), sync_count()}
          | {:error, term(), String.t() | nil, sync_count()}
          | {:rate_limited, String.t(), String.t() | nil, sync_count(), pos_integer()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    config_server = Keyword.fetch!(opts, :config_server)
    state = %{config_server: config_server, bot_user_id: nil, pending_sync: nil}

    config = ConfigServer.config(config_server)
    cache_sync = config.cache_sync

    if cache_sync_enabled?(cache_sync) do
      Logger.debug(
        "[SlackBot] channels cache sync scheduling first run interval_ms=#{cache_sync.interval_ms}"
      )

      schedule_sync(0)
      {:ok, state}
    else
      {:stop, :disabled}
    end
  end

  @impl true
  def handle_info(:sync, %{config_server: config_server} = state) do
    config = ConfigServer.config(config_server)
    cache_sync = config.cache_sync

    cond do
      cache_sync_enabled?(cache_sync) ->
        case run_sync(config, cache_sync, state.bot_user_id, state.pending_sync) do
          {:ok, bot_user_id, _count} ->
            schedule_sync(cache_sync.interval_ms)
            {:noreply, %{state | bot_user_id: bot_user_id, pending_sync: nil}}

          {:error, _reason, bot_user_id, _count} ->
            schedule_sync(cache_sync.interval_ms)
            {:noreply, %{state | bot_user_id: bot_user_id, pending_sync: nil}}

          {:rate_limited, bot_user_id, cursor, count, secs} ->
            Logger.debug(
              "[SlackBot] cache sync users.conversations pausing for #{secs}s cursor=#{inspect(cursor)} processed=#{count}"
            )

            schedule_sync(secs * 1_000)

            pending_sync = %{bot_user_id: bot_user_id, cursor: cursor, count: count}
            {:noreply, %{state | bot_user_id: bot_user_id, pending_sync: pending_sync}}
        end

      true ->
        {:noreply, state}
    end
  end

  @spec run_sync(Config.t(), map(), String.t() | nil, pending_sync() | nil) :: run_sync_result()
  defp run_sync(%Config{} = config, cache_sync, cached_bot_user_id, pending_sync) do
    resolved =
      case pending_sync do
        %{bot_user_id: bot_user_id} -> {:ok, bot_user_id}
        _ -> resolve_bot_user_id(config, cached_bot_user_id)
      end

    case resolved do
      {:ok, bot_user_id} ->
        cursor = pending_sync && pending_sync.cursor
        count = (pending_sync && pending_sync.count) || 0

        run_sync_with_identity(
          config,
          cache_sync,
          bot_user_id,
          cursor,
          count,
          pending_sync != nil
        )

      {:error, reason} ->
        Logger.debug(
          "[SlackBot] cache sync users.conversations skipped: #{inspect(reason)} instance=#{inspect(config.instance_name)}"
        )

        {:error, reason, cached_bot_user_id, 0}
    end
  end

  defp run_sync_with_identity(config, cache_sync, bot_user_id, cursor, count, resuming?) do
    log_sync_start(config, resuming?)

    {result, duration} = sync_channels(config, cache_sync, bot_user_id, cursor, count)

    case result do
      {:rate_limited, secs, resume_cursor, resume_count} ->
        {:rate_limited, bot_user_id, resume_cursor, resume_count, secs}

      _ ->
        status = sync_status(result)
        final_count = sync_count(result)

        Logger.debug(
          "[SlackBot] cache sync users.conversations completed status=#{inspect(status)} count=#{final_count}"
        )

        Telemetry.execute(
          config,
          [:cache, :sync],
          %{duration: duration, count: final_count},
          %{kind: :channels, status: status}
        )

        log_channel_cache_snapshot(config)

        attach_identity(result, bot_user_id)
    end
  end

  defp log_sync_start(%Config{} = config, false) do
    Logger.debug(
      "[SlackBot] cache sync users.conversations started for #{inspect(config.instance_name)}"
    )
  end

  defp log_sync_start(%Config{} = config, true) do
    Logger.debug(
      "[SlackBot] cache sync users.conversations resumed for #{inspect(config.instance_name)}"
    )
  end

  defp sync_channels(config, cache_sync, bot_user_id, cursor, count) do
    start = System.monotonic_time()
    result = do_sync_channels(config, cache_sync, bot_user_id, cursor, count)
    duration = System.monotonic_time() - start

    {result, duration}
  end

  @spec do_sync_channels(Config.t(), map(), String.t(), String.t() | nil, sync_count()) ::
          sync_result()
  defp do_sync_channels(%Config{} = config, cache_sync, bot_user_id, cursor, count) do
    case fetch_channels_page(config, cache_sync, bot_user_id, cursor) do
      {:page, resp, channels} ->
        processed = persist_page(config, channels)
        new_count = count + processed

        case pagination_decision(cache_sync, resp, new_count) do
          :halt ->
            {:ok, new_count}

          {:cont, next_cursor} ->
            do_sync_channels(config, cache_sync, bot_user_id, next_cursor, new_count)
        end

      {:rate_limited, secs} ->
        log_rate_limit(secs, cursor, count)
        {:rate_limited, secs, cursor, count}

      {:error, reason} ->
        Logger.debug(
          "[SlackBot] cache sync users.conversations error=#{inspect(reason)} processed=#{count}"
        )

        {:error, reason, count}

      {:unexpected, other} ->
        Logger.debug(
          "[SlackBot] cache sync users.conversations unexpected_response=#{inspect(other)} processed=#{count}"
        )

        {:error, {:invalid_response, other}, count}
    end
  end

  defp fetch_channels_page(config, cache_sync, bot_user_id, cursor) do
    body =
      cache_sync.users_conversations_opts
      |> Map.put("user", bot_user_id)
      |> maybe_put_cursor(cursor)

    case SlackBot.push(config, {"users.conversations", body}) do
      {:ok, %{"channels" => channels} = resp} when is_list(channels) ->
        {:page, resp, channels}

      {:error, {:rate_limited, secs}} when is_integer(secs) and secs > 0 ->
        {:rate_limited, secs}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:unexpected, other}
    end
  end

  defp pagination_decision(cache_sync, resp, count) do
    next_cursor =
      resp
      |> Map.get("response_metadata", %{})
      |> Map.get("next_cursor", "")

    cond do
      reached_page_limit?(cache_sync.page_limit, count) -> :halt
      next_cursor in [nil, ""] -> :halt
      true -> {:cont, next_cursor}
    end
  end

  defp persist_page(config, channels) when is_list(channels) do
    {channel_map, joined_ids} = index_channels(channels)
    persist_channels(config, channel_map, joined_ids)
    map_size(channel_map)
  end

  defp index_channels(channels) do
    Enum.reduce(channels, {%{}, MapSet.new()}, fn channel, {map_acc, joined_acc} ->
      case channel["id"] do
        id when is_binary(id) ->
          {
            Map.put(map_acc, id, channel),
            MapSet.put(joined_acc, id)
          }

        _ ->
          {map_acc, joined_acc}
      end
    end)
  end

  defp log_rate_limit(secs, cursor, count) do
    Logger.debug(
      "[SlackBot] cache sync users.conversations rate limited, retry_after=#{secs}s cursor=#{inspect(cursor)} processed=#{count}"
    )
  end

  defp persist_channels(%Config{} = config, channels_by_id, joined_ids) do
    Logger.debug(
      "[SlackBot] persist_channels instance=#{inspect(config.instance_name)} channels_by_id_count=#{map_size(channels_by_id)} joined_ids_count=#{MapSet.size(joined_ids)} joined_ids_sample=#{inspect(joined_ids |> Enum.take(20))}"
    )

    Enum.each(joined_ids, fn id ->
      if is_binary(id), do: Cache.join_channel(config, id)
    end)

    if map_size(channels_by_id) > 0 do
      existing =
        config
        |> Cache.metadata()
        |> Map.get("channels_by_id", %{})

      merged = Map.merge(existing, channels_by_id)

      Cache.put_metadata(config, %{"channels_by_id" => merged})
    end
  end

  defp log_channel_cache_snapshot(%Config{} = config) do
    joined_ids = Cache.channels(config)

    channels_by_id =
      config
      |> Cache.metadata()
      |> Map.get("channels_by_id", %{})

    meta_ids_sample = channels_by_id |> Map.keys() |> Enum.take(10)

    Logger.debug(
      "[SlackBot] cache sync channels snapshot instance=#{inspect(config.instance_name)} joined_count=#{length(joined_ids)} joined_ids=#{inspect(joined_ids)} meta_count=#{map_size(channels_by_id)} meta_ids_sample=#{inspect(meta_ids_sample)}"
    )
  end

  defp schedule_sync(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :sync, delay_ms)
  end

  defp schedule_sync(_delay_ms) do
    send(self(), :sync)
  end

  defp maybe_put_cursor(body, nil), do: body

  defp maybe_put_cursor(body, cursor) when is_binary(cursor) and cursor != "" do
    Map.put(body, "cursor", cursor)
  end

  defp maybe_put_cursor(body, _), do: body

  defp reached_page_limit?(:infinity, _count), do: false

  defp reached_page_limit?(limit, count) when is_integer(limit) and limit > 0 do
    count >= limit
  end

  defp reached_page_limit?(_, _), do: false

  @spec resolve_bot_user_id(Config.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  defp resolve_bot_user_id(%Config{assigns: %{bot_user_id: id}}, _cached_id)
       when is_binary(id) and id != "",
       do: {:ok, id}

  defp resolve_bot_user_id(_config, cached_id) when is_binary(cached_id) and cached_id != "",
    do: {:ok, cached_id}

  defp resolve_bot_user_id(%Config{} = config, _cached_id),
    do: discover_bot_user_id(config)

  defp discover_bot_user_id(%Config{} = config) do
    Logger.debug(
      "[SlackBot] cache sync users.conversations discovering bot identity for #{inspect(config.instance_name)}"
    )

    case SlackBot.push(config, {"auth.test", %{}}) do
      {:ok, %{"user_id" => user_id}} when is_binary(user_id) and user_id != "" ->
        {:ok, user_id}

      {:ok, _} ->
        {:error, :invalid_auth_test_response}

      {:error, reason} ->
        {:error, {:auth_test_failed, reason}}
    end
  end

  defp cache_sync_enabled?(%{enabled: enabled, kinds: kinds})
       when is_boolean(enabled) and is_list(kinds),
       do: enabled and :channels in kinds

  defp cache_sync_enabled?(_), do: false

  defp sync_status({:ok, _count}), do: :ok
  defp sync_status({:error, _reason, _count}), do: :error

  defp sync_count({:ok, count}), do: count
  defp sync_count({:error, _reason, count}), do: count

  defp attach_identity({:ok, count}, bot_user_id), do: {:ok, bot_user_id, count}

  defp attach_identity({:error, reason, count}, bot_user_id),
    do: {:error, reason, bot_user_id, count}
end
