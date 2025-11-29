defmodule BasicBot.TelemetryProbe do
  @moduledoc false

  use GenServer

  alias SlackBot.Cache

  @events [
    [:api, :request],
    [:api, :rate_limited],
    [:tier_limiter, :decision],
    [:rate_limiter, :decision],
    [:rate_limiter, :drain],
    [:cache, :sync],
    [:connection, :state],
    [:connection, :rate_limited],
    [:healthcheck, :ping],
    [:healthcheck, :disabled],
    [:ack, :http]
  ]

  def ensure_started(bot \\ BasicBot.SlackBot) do
    name = server_name(bot)

    case Process.whereis(name) do
      nil ->
        {:ok, _pid} = start_link(bot: bot, name: name)
        :ok

      _ ->
        :ok
    end
  end

  def start_link(opts) do
    bot = Keyword.fetch!(opts, :bot)
    name = Keyword.get(opts, :name, server_name(bot))
    GenServer.start_link(__MODULE__, [bot: bot], name: name)
  end

  def reset(bot \\ BasicBot.SlackBot) do
    ensure_started(bot)
    GenServer.call(server_name(bot), :reset)
  end

  def snapshot(bot \\ BasicBot.SlackBot) do
    ensure_started(bot)
    GenServer.call(server_name(bot), :snapshot)
  end

  @impl GenServer
  def init(opts) do
    bot = Keyword.fetch!(opts, :bot)
    config = fetch_config(bot)
    prefix = Map.get(config, :telemetry_prefix, [:slackbot])
    prefix_len = length(prefix)

    handler_id = {:basic_bot_probe, self()}

    :telemetry.attach_many(
      handler_id,
      Enum.map(@events, &(prefix ++ &1)),
      &__MODULE__.handle_event/4,
      %{pid: self(), prefix_len: prefix_len}
    )

    {:ok,
     %{
       bot: bot,
       handler_id: handler_id,
       stats: initial_stats()
     }}
  end

  @impl GenServer
  def terminate(_reason, %{handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    :ok
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | stats: initial_stats()}}
  end

  def handle_call(:snapshot, _from, %{bot: bot, stats: stats} = state) do
    {:reply, build_snapshot(stats, bot), state}
  end

  @impl GenServer
  def handle_info({:telemetry_event, suffix, measurements, metadata}, state) do
    stats =
      case suffix do
        [:api, :request] ->
          update_api(stats(state), measurements, metadata)

        [:api, :rate_limited] ->
          put_in(stats(state).api.rate_limited, stats(state).api.rate_limited + 1)

        [:tier_limiter, :decision] ->
          update_tier(stats(state), measurements, metadata)

        [:rate_limiter, :decision] ->
          update_rate_limiter(stats(state), measurements, metadata)

        [:rate_limiter, :drain] ->
          update_in(stats(state).rate_limiter.drains, &(&1 + Map.get(measurements, :drained, 0)))

        [:cache, :sync] ->
          update_cache_sync(stats(state), measurements, metadata)

        [:connection, :state] ->
          update_connection_state(stats(state), metadata)

        [:connection, :rate_limited] ->
          update_in(stats(state).connection.rate_limited, &(&1 + 1))

        [:healthcheck, :ping] ->
          update_health(stats(state), metadata)

        [:healthcheck, :disabled] ->
          put_in(stats(state).health.disabled, true)

        [:ack, :http] ->
          update_ack(stats(state), metadata)

        _ ->
          stats(state)
      end

    {:noreply, %{state | stats: stats}}
  end

  def handle_event(event, measurements, metadata, %{pid: pid, prefix_len: len}) do
    suffix = Enum.drop(event, len)
    send(pid, {:telemetry_event, suffix, measurements, metadata})
  end

  defp stats(%{stats: stats}), do: stats

  defp update_api(stats, measurements, metadata) do
    duration = Map.get(measurements, :duration, 0)
    status = Map.get(metadata, :status, :unknown)

    stats
    |> update_in([:api, :total], &(&1 + 1))
    |> update_status([:api], status)
    |> update_in([:api, :duration], &(&1 + duration))
  end

  defp update_tier(stats, measurements, metadata) do
    decision = Map.get(metadata, :decision, :allow)
    queue_length = Map.get(measurements, :queue_length, 0)
    method = Map.get(metadata, :method, "unknown")

    stats
    |> update_decision([:tier], decision)
    |> put_in([:tier, :last_queue], queue_length)
    |> update_in([:tier, :methods, method], &((&1 || 0) + queue_length))
  end

  defp update_rate_limiter(stats, measurements, metadata) do
    decision = Map.get(metadata, :decision, :allow)
    queue_length = Map.get(measurements, :queue_length, 0)

    stats
    |> update_decision([:rate_limiter], decision)
    |> put_in([:rate_limiter, :last_queue], queue_length)
  end

  defp update_cache_sync(stats, measurements, metadata) do
    stats
    |> put_in([:cache_sync, :last_kind], Map.get(metadata, :kind))
    |> put_in([:cache_sync, :last_status], Map.get(metadata, :status))
    |> put_in([:cache_sync, :last_count], Map.get(measurements, :count, 0))
    |> put_in([:cache_sync, :last_duration], Map.get(measurements, :duration, 0))
  end

  defp update_connection_state(stats, metadata) do
    state = Map.get(metadata, :state, :unknown)

    stats
    |> update_in([:connection, :states, state], fn current -> (current || 0) + 1 end)
    |> put_in([:connection, :last_state], state)
  end

  defp build_snapshot(stats, bot) do
    cache_snapshot = cache_stats(bot)

    %{
      generated_at: DateTime.utc_now(),
      cache: cache_snapshot |> Map.merge(cache_sync_details(stats.cache_sync)),
      api: api_details(stats.api),
      tier: tier_details(stats.tier),
      rate_limiter: rate_limiter_details(stats.rate_limiter),
      connection: connection_details(stats.connection),
      health: stats.health,
      ack: stats.ack
    }
  end

  defp cache_sync_details(%{
         last_kind: kind,
         last_status: status,
         last_count: count,
         last_duration: duration
       }) do
    %{
      last_sync_kind: kind,
      last_sync_status: status,
      last_sync_count: count,
      last_sync_duration_ms: to_ms(duration)
    }
  end

  defp api_details(%{
         total: total,
         ok: ok,
         error: error,
         unknown: unknown,
         duration: duration,
         rate_limited: rate_limited
       }) do
    avg_ms =
      if total > 0 do
        to_ms(duration) / total
      else
        0.0
      end

    %{
      total: total,
      ok: ok,
      error: error,
      unknown: unknown,
      avg_duration_ms: Float.round(avg_ms, 2),
      rate_limited: rate_limited
    }
  end

  defp tier_details(%{
         allow: allow,
         queue: queue,
         other: other,
         methods: methods,
         last_queue: last_queue
       }) do
    busiest =
      methods
      |> Enum.max_by(fn {_method, queued} -> queued end, fn -> nil end)

    %{
      allow: allow,
      queue: queue,
      other: other,
      last_queue: last_queue,
      busiest: busiest
    }
  end

  defp rate_limiter_details(%{
         allow: allow,
         queue: queue,
         other: other,
         drains: drains,
         last_queue: last_queue
       }) do
    %{
      allow: allow,
      queue: queue,
      other: other,
      drains: drains,
      last_queue: last_queue
    }
  end

  defp connection_details(%{states: states, last_state: last_state, rate_limited: rate_limited}) do
    %{
      states: states,
      last_state: last_state,
      rate_limited: rate_limited
    }
  end

  defp to_ms(native) when is_number(native) do
    native
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1000)
    |> Float.round(2)
  end

  defp to_ms(_), do: 0.0

  defp update_health(stats, metadata) do
    status = Map.get(metadata, :status, :unknown)

    stats
    |> put_in([:health, :last_status], status)
    |> update_in([:health, :failures], fn failures ->
      if status in [:error, :fatal], do: failures + 1, else: failures
    end)
  end

  defp update_ack(stats, metadata) do
    status = Map.get(metadata, :status, :unknown)
    update_status(stats, [:ack], status)
  end

  defp update_status(stats, path, status) do
    bucket =
      case status do
        :ok -> :ok
        :error -> :error
        _ -> :unknown
      end

    update_in(stats, path ++ [bucket], &(&1 + 1))
  end

  defp update_decision(stats, path, decision) do
    bucket =
      case decision do
        :allow -> :allow
        :queue -> :queue
        _ -> :other
      end

    update_in(stats, path ++ [bucket], &(&1 + 1))
  end

  defp cache_stats(bot) do
    users = safe(fn -> bot |> Cache.users() |> map_size() end, 0)
    channels = safe(fn -> bot |> Cache.channels() |> length() end, 0)

    %{
      users: users,
      channels: channels
    }
  end

  defp initial_stats do
    %{
      api: %{total: 0, ok: 0, error: 0, unknown: 0, duration: 0, rate_limited: 0},
      tier: %{allow: 0, queue: 0, other: 0, methods: %{}, last_queue: 0},
      rate_limiter: %{allow: 0, queue: 0, other: 0, drains: 0, last_queue: 0},
      cache_sync: %{last_kind: nil, last_status: nil, last_count: 0, last_duration: 0},
      connection: %{states: %{}, last_state: nil, rate_limited: 0},
      health: %{last_status: nil, failures: 0, disabled: false},
      ack: %{ok: 0, error: 0, unknown: 0}
    }
  end

  defp server_name(bot) when is_atom(bot) do
    Module.concat(bot, TelemetryProbe)
  end

  defp fetch_config(bot) do
    safe(fn -> SlackBot.config(bot) end, %{telemetry_prefix: [:slackbot]})
  end

  defp safe(fun, default) when is_function(fun, 0) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      :exit, _ -> default
      :throw, _ -> default
      _kind, _value -> default
    end
  end
end
