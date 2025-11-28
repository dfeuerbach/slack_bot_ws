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

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    config_server = Keyword.fetch!(opts, :config_server)
    state = %{config_server: config_server}

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
  def handle_info(:sync, %{config_server: config_server} = state) do
    config = ConfigServer.config(config_server)
    cache_sync = config.cache_sync

    if cache_sync.enabled and :users in cache_sync.kinds do
      run_sync(config, cache_sync)
      schedule_sync(cache_sync.interval_ms)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  defp run_sync(%Config{} = config, cache_sync) do
    Logger.debug("[SlackBot] cache sync users.list started for #{inspect(config.instance_name)}")

    start = System.monotonic_time()
    result = do_sync_users(config, cache_sync, nil, 0)
    duration = System.monotonic_time() - start

    {status, count} =
      case result do
        {:ok, count} -> {:ok, count}
        {:error, _reason, count} -> {:error, count}
      end

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
        Logger.debug(
          "[SlackBot] cache sync users.list rate limited, retry_after=#{secs}s cursor=#{inspect(cursor)} processed=#{count}"
        )

        :timer.sleep(secs * 1_000)
        do_sync_users(config, cache_sync, cursor, count)

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
