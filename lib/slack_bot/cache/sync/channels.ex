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

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    config_server = Keyword.fetch!(opts, :config_server)
    state = %{config_server: config_server, bot_user_id: nil}

    config = ConfigServer.config(config_server)
    cache_sync = config.cache_sync

    if cache_sync.enabled and :channels in cache_sync.kinds do
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

    if cache_sync.enabled and :channels in cache_sync.kinds do
      {_status, bot_user_id} = run_sync(config, cache_sync, state.bot_user_id)
      schedule_sync(cache_sync.interval_ms)
      {:noreply, %{state | bot_user_id: bot_user_id}}
    else
      {:noreply, state}
    end
  end

  defp run_sync(%Config{} = config, cache_sync, bot_user_id) do
    with {:ok, bot_user_id} <- ensure_bot_user_id(config, bot_user_id) do
      Logger.debug(
        "[SlackBot] cache sync users.conversations started for #{inspect(config.instance_name)}"
      )

      start = System.monotonic_time()
      result = do_sync_channels(config, cache_sync, bot_user_id, nil, 0)
      duration = System.monotonic_time() - start

      {status, count} =
        case result do
          {:ok, count} -> {:ok, count}
          {:error, _reason, count} -> {:error, count}
        end

      Logger.debug(
        "[SlackBot] cache sync users.conversations completed status=#{inspect(status)} count=#{count}"
      )

      Telemetry.execute(
        config,
        [:cache, :sync],
        %{duration: duration, count: count},
        %{kind: :channels, status: status}
      )

      log_channel_cache_snapshot(config)
      {:ok, bot_user_id}
    else
      {:error, reason} ->
        Logger.debug(
          "[SlackBot] cache sync users.conversations skipped: #{inspect(reason)} instance=#{inspect(config.instance_name)}"
        )

        {:error, bot_user_id}
    end
  end

  defp do_sync_channels(%Config{} = config, cache_sync, bot_user_id, cursor, count) do
    body =
      cache_sync.users_conversations_opts
      |> Map.put("user", bot_user_id)
      |> maybe_put_cursor(cursor)

    case SlackBot.push(config, {"users.conversations", body}) do
      {:ok, %{"channels" => channels} = resp} when is_list(channels) ->
        {channel_map, joined_ids} =
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

        persist_channels(config, channel_map, joined_ids)
        new_count = count + map_size(channel_map)

        next_cursor =
          resp
          |> Map.get("response_metadata", %{})
          |> Map.get("next_cursor", "")

        cond do
          reached_page_limit?(cache_sync.page_limit, new_count) or next_cursor in [nil, ""] ->
            {:ok, new_count}

          true ->
            do_sync_channels(
              config,
              cache_sync,
              bot_user_id,
              next_cursor,
              new_count
            )
        end

      {:error, {:rate_limited, secs}} when is_integer(secs) and secs > 0 ->
        Logger.debug(
          "[SlackBot] cache sync users.conversations rate limited, retry_after=#{secs}s cursor=#{inspect(cursor)} processed=#{count}"
        )

        :timer.sleep(secs * 1_000)
        do_sync_channels(config, cache_sync, bot_user_id, cursor, count)

      {:error, reason} ->
        Logger.debug(
          "[SlackBot] cache sync users.conversations error=#{inspect(reason)} processed=#{count}"
        )

        {:error, reason, count}

      other ->
        Logger.debug(
          "[SlackBot] cache sync users.conversations unexpected_response=#{inspect(other)} processed=#{count}"
        )

        {:error, {:invalid_response, other}, count}
    end
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

  defp ensure_bot_user_id(%Config{assigns: %{bot_user_id: id}}, _cached_id) when is_binary(id),
    do: {:ok, id}

  defp ensure_bot_user_id(_config, cached_id) when is_binary(cached_id), do: {:ok, cached_id}

  defp ensure_bot_user_id(%Config{} = config, _cached_id), do: fetch_bot_user_id(config)

  defp fetch_bot_user_id(%Config{} = config) do
    Logger.debug(
      "[SlackBot] cache sync users.conversations discovering bot identity for #{inspect(config.instance_name)}"
    )

    case SlackBot.push(config, {"auth.test", %{}}) do
      {:ok, %{"user_id" => user_id}} when is_binary(user_id) ->
        {:ok, user_id}

      {:ok, _} ->
        {:error, :invalid_auth_test_response}

      {:error, reason} ->
        {:error, {:auth_test_failed, reason}}
    end
  end
end
