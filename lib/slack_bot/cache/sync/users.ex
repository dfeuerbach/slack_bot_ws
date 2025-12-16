defmodule SlackBot.Cache.Sync.Users do
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
  @type pending_sync :: %{
          cursor: String.t() | nil,
          count: sync_count()
        }

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    config_server = Keyword.fetch!(opts, :config_server)
    state = %{config_server: config_server, pending_sync: nil}

    config = ConfigServer.config(config_server)
    cache_sync = config.cache_sync

    if cache_sync.enabled and :users in cache_sync.kinds do
      Logger.debug(
        "[SlackBot] users cache sync scheduling first run interval_ms=#{cache_sync.interval_ms}"
      )

      schedule_sync(0)
      {:ok, state}
    else
      {:stop, :disabled}
    end
  end

  @impl true
  def handle_info(:sync, %{config_server: config_server, pending_sync: pending_sync} = state) do
    config = ConfigServer.config(config_server)
    cache_sync = config.cache_sync

    if cache_sync.enabled and :users in cache_sync.kinds do
      case run_sync(config, cache_sync, pending_sync) do
        {:ok, _count} ->
          schedule_sync(cache_sync.interval_ms)
          {:noreply, %{state | pending_sync: nil}}

        {:error, _reason, _count} ->
          schedule_sync(cache_sync.interval_ms)
          {:noreply, %{state | pending_sync: nil}}

        {:rate_limited, secs, cursor, count} ->
          Logger.debug(
            "[SlackBot] cache sync users.list pausing for #{secs}s cursor=#{inspect(cursor)} processed=#{count}"
          )

          schedule_sync(secs * 1_000)
          {:noreply, %{state | pending_sync: %{cursor: cursor, count: count}}}
      end
    else
      {:noreply, state}
    end
  end

  defp run_sync(%Config{} = config, cache_sync, pending_sync) do
    log_sync_start(config, pending_sync != nil)

    start = System.monotonic_time()
    cursor = pending_sync && pending_sync.cursor
    count = (pending_sync && pending_sync.count) || 0
    result = do_sync_users(config, cache_sync, cursor, count)
    duration = System.monotonic_time() - start

    {status, count} =
      case result do
        {:ok, count} -> {:ok, count}
        {:error, _reason, count} -> {:error, count}
        {:rate_limited, _secs, _cursor, count} -> {:rate_limited, count}
      end

    if status in [:ok, :error] do
      Logger.debug(
        "[SlackBot] cache sync users.list completed status=#{inspect(status)} count=#{count}"
      )

      Telemetry.execute(
        config,
        [:cache, :sync],
        %{duration: duration, count: count},
        %{kind: :users, status: status}
      )

      log_user_cache_snapshot(config)
    end

    attach_duration(result, duration)
  end

  defp attach_duration({:ok, count}, _duration), do: {:ok, count}
  defp attach_duration({:error, reason, count}, _duration), do: {:error, reason, count}

  defp attach_duration({:rate_limited, secs, cursor, count}, _duration),
    do: {:rate_limited, secs, cursor, count}

  defp log_sync_start(%Config{} = config, false) do
    Logger.debug("[SlackBot] cache sync users.list started for #{inspect(config.instance_name)}")
  end

  defp log_sync_start(%Config{} = config, true) do
    Logger.debug("[SlackBot] cache sync users.list resumed for #{inspect(config.instance_name)}")
  end

  defp do_sync_users(%Config{} = config, cache_sync, cursor, count) do
    body =
      %{"limit" => 500}
      |> maybe_put_cursor(cursor)
      |> maybe_put_presence(cache_sync)

    case SlackBot.push(config, {"users.list", body}) do
      {:ok, %{"members" => members} = resp} when is_list(members) ->
        Enum.each(members, fn user -> Cache.put_user(config, user) end)

        new_count = count + length(members)

        next_cursor =
          resp
          |> Map.get("response_metadata", %{})
          |> Map.get("next_cursor", "")

        cond do
          reached_page_limit?(cache_sync.page_limit, new_count) ->
            {:ok, new_count}

          next_cursor in [nil, ""] ->
            {:ok, new_count}

          true ->
            do_sync_users(config, cache_sync, next_cursor, new_count)
        end

      {:error, {:rate_limited, secs}} when is_integer(secs) and secs > 0 ->
        {:rate_limited, secs, cursor, count}

      {:error, reason} ->
        Logger.debug(
          "[SlackBot] cache sync users.list error=#{inspect(reason)} processed=#{count}"
        )

        {:error, reason, count}

      other ->
        Logger.debug(
          "[SlackBot] cache sync users.list unexpected_response=#{inspect(other)} processed=#{count}"
        )

        {:error, {:invalid_response, other}, count}
    end
  end

  defp log_user_cache_snapshot(%Config{} = config) do
    users = Cache.users(config)
    sample_ids = users |> Map.keys() |> Enum.take(10)

    Logger.debug(
      "[SlackBot] cache sync users snapshot instance=#{inspect(config.instance_name)} count=#{map_size(users)} sample_user_ids=#{inspect(sample_ids)}"
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

  defp maybe_put_presence(body, %{include_presence: true}) do
    Map.put(body, "presence", true)
  end

  defp maybe_put_presence(body, _), do: body

  defp reached_page_limit?(:infinity, _count), do: false

  defp reached_page_limit?(limit, count) when is_integer(limit) and limit > 0 do
    count >= limit
  end

  defp reached_page_limit?(_, _), do: false
end
