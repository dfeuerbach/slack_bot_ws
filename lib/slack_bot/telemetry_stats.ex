defmodule SlackBot.TelemetryStats do
  @moduledoc """
  Optional Telemetry aggregator that rolls SlackBot events into cache-backed metrics.

  This module attaches to SlackBot's Telemetry stream, aggregates events into running
  counters, and periodically persists snapshots to the cache. It provides production
  observability without external dependencies—just enable it in config and query via
  `snapshot/1`.

  ## Why Use TelemetryStats?

  - **Production debugging** - Quickly see API call rates, handler outcomes, and limiter activity
  - **Health monitoring** - Track connection states and health check results
  - **Performance analysis** - Measure average API latency and handler execution time
  - **Multi-node visibility** - When using Redis cache, stats are visible across nodes

  ## Configuration

  Enable in your bot config:

      config :my_app, MyApp.SlackBot,
        telemetry_stats: [
          enabled: true,
          flush_interval_ms: 15_000,  # How often to persist to cache
          ttl_ms: 300_000              # How long to keep stale snapshots
        ]

  ## Usage

  Query the latest snapshot:

      iex> SlackBot.TelemetryStats.snapshot(MyApp.SlackBot)
      %{
        stats: %{
          api: %{total: 42, ok: 40, error: 2, avg_duration_ms: 150.5, ...},
          handler: %{status: %{ok: 15, error: 1}, duration_ms: 1200, ...},
          cache: %{users: 100, channels: 25},
          connection: %{states: %{connected: 5, disconnected: 1}},
          rate_limiter: %{allow: 40, queue: 2, drains: 12},
          tier: %{allow: 38, queue: 0, suspensions: 0}
        },
        generated_at_ms: 1733097600000
      }

  ## In Production

  Send snapshots to monitoring dashboards, log aggregators, or Slack itself:

      def periodic_report(channel_id) do
        snapshot = SlackBot.TelemetryStats.snapshot(MyBot)
        metrics = format_metrics(snapshot)

        SlackBot.push(MyBot, {"chat.postMessage", %{
          channel: channel_id,
          text: "Bot health report",
          blocks: metrics
        }})
      end

  ## Without TelemetryStats

  If you don't enable TelemetryStats, you can still:

  - Attach custom `:telemetry` handlers directly to SlackBot events
  - Use `SlackBot.Diagnostics` for payload-level debugging
  - Integrate with LiveDashboard via the telemetry events documented in the
    [Telemetry Guide](https://hexdocs.pm/slack_bot_ws/telemetry_dashboard.html)

  ## See Also

  - [Telemetry Guide](https://hexdocs.pm/slack_bot_ws/telemetry_dashboard.html)
  - `SlackBot.Diagnostics` - For payload capture and replay
  - `BasicBot` - Example using telemetry snapshots in slash commands
  """

  use GenServer

  alias SlackBot.Cache

  @events [
    [:api, :request],
    [:api, :rate_limited],
    [:connection, :state],
    [:connection, :rate_limited],
    [:healthcheck, :ping],
    [:cache, :sync],
    [:tier_limiter, :decision],
    [:tier_limiter, :suspend],
    [:tier_limiter, :resume],
    [:rate_limiter, :decision],
    [:rate_limiter, :drain],
    [:rate_limiter, :blocked],
    [:handler, :ingress],
    [:handler, :dispatch, :stop],
    [:handler, :middleware, :halt],
    [:ack, :http]
  ]

  @type option :: {:config, SlackBot.Config.t()} | {:name, GenServer.name()}

  @doc false
  @spec child_spec(SlackBot.Config.t()) :: Supervisor.child_spec()
  def child_spec(%SlackBot.Config{} = config) do
    name = Module.concat(config.instance_name, TelemetryStats)

    %{
      id: name,
      start: {__MODULE__, :start_link, [[name: name, config: config]]},
      type: :worker
    }
  end

  @doc false
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the latest cached telemetry snapshot for the given bot (or config).
  """
  @spec snapshot(SlackBot.Config.t() | GenServer.server()) :: map()
  def snapshot(%SlackBot.Config{} = config) do
    Cache.metadata(config)
    |> Map.get("telemetry_stats", %{})
  end

  def snapshot(server) do
    server
    |> SlackBot.config()
    |> snapshot()
  end

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    stats_opts = Map.get(config, :telemetry_stats, %{})

    if Map.get(stats_opts, :enabled) do
      prefix = Map.get(config, :telemetry_prefix, [:slackbot])

      handler_id =
        {:slackbot_telemetry_stats, config.instance_name, System.unique_integer([:positive])}

      state = %{
        config: config,
        prefix: prefix,
        prefix_len: length(prefix),
        handler_id: handler_id,
        stats: initial_stats(),
        flush_interval_ms: stats_opts.flush_interval_ms,
        ttl_ms: stats_opts.ttl_ms
      }

      :ok = attach_handler(state)
      schedule_flush(state.flush_interval_ms)
      {:ok, state}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:flush, state) do
    persist_snapshot(state)
    schedule_flush(state.flush_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:telemetry_event, suffix, measurements, metadata}, state) do
    stats = apply_event(state.stats, suffix, measurements, metadata)
    {:noreply, %{state | stats: stats}}
  end

  @impl true
  def terminate(_reason, %{handler_id: handler_id} = state) do
    :telemetry.detach(handler_id)
    persist_snapshot(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @doc false
  def handle_event(event, measurements, metadata, %{pid: pid, prefix_len: len}) do
    suffix = Enum.drop(event, len)
    send(pid, {:telemetry_event, suffix, measurements, metadata})
  end

  defp attach_handler(%{handler_id: handler_id, prefix: prefix, prefix_len: len}) do
    events = Enum.map(@events, &(prefix ++ &1))
    handler_config = %{pid: self(), prefix_len: len}
    :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, handler_config)
  end

  defp schedule_flush(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :flush, interval_ms)
  end

  defp persist_snapshot(%{config: config, stats: stats, ttl_ms: ttl, flush_interval_ms: flush}) do
    now = System.system_time(:millisecond)

    snapshot = %{
      stats: stats,
      generated_at_ms: now,
      expires_at_ms: now + ttl,
      flush_interval_ms: flush
    }

    Cache.put_metadata(config, %{"telemetry_stats" => snapshot})
  end

  defp initial_stats do
    %{
      api: %{
        total: 0,
        ok: 0,
        error: 0,
        exception: 0,
        unknown: 0,
        duration_ms: 0.0,
        rate_limited: 0,
        last_method: nil,
        last_rate_limited: nil
      },
      cache_sync: %{
        last_kind: nil,
        last_status: nil,
        last_count: 0,
        last_duration_ms: 0.0
      },
      connection: %{
        states: %{},
        last_state: nil,
        rate_limited: 0,
        last_rate_delay_ms: nil
      },
      health: %{
        statuses: %{},
        last_status: nil
      },
      tier: %{
        allow: 0,
        queue: 0,
        other: 0,
        last_queue: 0,
        last_tokens: 0.0,
        suspensions: 0,
        resumes: 0,
        last_suspend: nil,
        last_resume: nil
      },
      rate_limiter: %{
        allow: 0,
        queue: 0,
        other: 0,
        drains: 0,
        blocked: 0,
        last_queue: 0,
        last_delay_ms: nil,
        last_block_delay_ms: nil
      },
      handler: %{
        status: %{ok: 0, error: 0, exception: 0, halted: 0, unknown: 0},
        duration_ms: 0.0,
        ingress: %{queue: 0, duplicate: 0},
        middleware_halts: 0
      },
      ack: %{
        ok: 0,
        error: 0,
        exception: 0,
        unknown: 0
      }
    }
  end

  defp apply_event(stats, [:api, :request], measurements, metadata) do
    duration_ms = to_ms(Map.get(measurements, :duration, 0))
    status = Map.get(metadata, :status, :unknown)

    stats
    |> increment([:api, :total])
    |> increment_status([:api], status)
    |> update_in([:api, :duration_ms], &(&1 + duration_ms))
    |> put_in([:api, :last_method], Map.get(metadata, :method))
  end

  defp apply_event(stats, [:api, :rate_limited], measurements, metadata) do
    info = %{
      method: Map.get(metadata, :method),
      key: Map.get(metadata, :key),
      retry_after_ms: Map.get(measurements, :retry_after_ms),
      observed_at_ms: Map.get(measurements, :observed_at_ms)
    }

    stats
    |> increment([:api, :rate_limited])
    |> put_in([:api, :last_rate_limited], info)
  end

  defp apply_event(stats, [:connection, :state], _measurements, metadata) do
    state_value = Map.get(metadata, :state, :unknown)

    stats
    |> update_in([:connection, :states], fn states ->
      Map.update(states, state_value, 1, &(&1 + 1))
    end)
    |> put_in([:connection, :last_state], state_value)
  end

  defp apply_event(stats, [:connection, :rate_limited], measurements, _metadata) do
    stats
    |> increment([:connection, :rate_limited])
    |> put_in([:connection, :last_rate_delay_ms], Map.get(measurements, :delay_ms))
  end

  defp apply_event(stats, [:healthcheck, :ping], measurements, metadata) do
    status = Map.get(metadata, :status, :unknown)
    duration_ms = to_ms(Map.get(measurements, :duration, 0))

    stats
    |> update_in([:health, :statuses], fn statuses ->
      Map.update(statuses, status, 1, &(&1 + 1))
    end)
    |> put_in([:health, :last_status], %{
      status: status,
      duration_ms: duration_ms,
      reason: Map.get(metadata, :reason)
    })
  end

  defp apply_event(stats, [:cache, :sync], measurements, metadata) do
    stats
    |> put_in([:cache_sync, :last_kind], Map.get(metadata, :kind))
    |> put_in([:cache_sync, :last_status], Map.get(metadata, :status))
    |> put_in([:cache_sync, :last_count], Map.get(measurements, :count, 0))
    |> put_in(
      [:cache_sync, :last_duration_ms],
      to_ms(Map.get(measurements, :duration, 0))
    )
  end

  defp apply_event(stats, [:tier_limiter, :decision], measurements, metadata) do
    decision = Map.get(metadata, :decision, :other)
    queue_length = Map.get(measurements, :queue_length, 0)
    tokens = Map.get(measurements, :tokens, 0.0)

    stats
    |> increment(decision_path(:tier, decision))
    |> put_in([:tier, :last_queue], queue_length)
    |> put_in([:tier, :last_tokens], Float.round(tokens || 0.0, 4))
  end

  defp apply_event(stats, [:tier_limiter, :suspend], measurements, metadata) do
    info = %{
      method: Map.get(metadata, :method),
      scope_key: Map.get(metadata, :scope_key),
      delay_ms: Map.get(measurements, :delay_ms)
    }

    stats
    |> increment([:tier, :suspensions])
    |> put_in([:tier, :last_suspend], info)
  end

  defp apply_event(stats, [:tier_limiter, :resume], measurements, metadata) do
    info = %{
      method: Map.get(metadata, :method),
      scope_key: Map.get(metadata, :scope_key),
      queue_length: Map.get(measurements, :queue_length),
      tokens: Float.round(Map.get(measurements, :tokens, 0.0) || 0.0, 4)
    }

    stats
    |> increment([:tier, :resumes])
    |> put_in([:tier, :last_resume], info)
  end

  defp apply_event(stats, [:rate_limiter, :decision], measurements, metadata) do
    decision = Map.get(metadata, :decision, :other)

    stats
    |> increment(decision_path(:rate_limiter, decision))
    |> put_in([:rate_limiter, :last_queue], Map.get(measurements, :queue_length, 0))
    |> put_in([:rate_limiter, :last_in_flight], Map.get(measurements, :in_flight, 0))
  end

  defp apply_event(stats, [:rate_limiter, :drain], measurements, _metadata) do
    stats
    |> increment([:rate_limiter, :drains], Map.get(measurements, :drained, 0))
    |> put_in([:rate_limiter, :last_delay_ms], Map.get(measurements, :delay_ms))
  end

  defp apply_event(stats, [:rate_limiter, :blocked], measurements, _metadata) do
    stats
    |> increment([:rate_limiter, :blocked])
    |> put_in([:rate_limiter, :last_block_delay_ms], Map.get(measurements, :delay_ms))
  end

  defp apply_event(stats, [:handler, :ingress], _measurements, metadata) do
    decision =
      case Map.get(metadata, :decision) do
        :duplicate -> :duplicate
        _ -> :queue
      end

    increment(stats, [:handler, :ingress, decision])
  end

  defp apply_event(stats, [:handler, :dispatch, :stop], measurements, metadata) do
    duration_ms = to_ms(Map.get(measurements, :duration, 0))
    status = Map.get(metadata, :status, :unknown)

    stats
    |> increment_status([:handler, :status], status)
    |> update_in([:handler, :duration_ms], &(&1 + duration_ms))
  end

  defp apply_event(stats, [:handler, :middleware, :halt], _measurements, _metadata) do
    increment(stats, [:handler, :middleware_halts])
  end

  defp apply_event(stats, [:ack, :http], _measurements, metadata) do
    status = Map.get(metadata, :status, :unknown)
    increment_status(stats, [:ack], status)
  end

  defp apply_event(stats, _event, _measurements, _metadata), do: stats

  defp increment(stats, path, delta \\ 1) do
    update_in(stats, path, &(&1 + delta))
  end

  defp increment_status(stats, path, status) do
    bucket =
      case status do
        :ok -> :ok
        :error -> :error
        :exception -> :exception
        :halted -> :halted
        _ -> :unknown
      end

    update_in(stats, path ++ [bucket], &(&1 + 1))
  end

  defp decision_path(:tier, :allow), do: [:tier, :allow]
  defp decision_path(:tier, :queue), do: [:tier, :queue]
  defp decision_path(:tier, _), do: [:tier, :other]

  defp decision_path(:rate_limiter, :allow), do: [:rate_limiter, :allow]
  defp decision_path(:rate_limiter, :queue), do: [:rate_limiter, :queue]
  defp decision_path(:rate_limiter, _), do: [:rate_limiter, :other]

  defp to_ms(native) when is_integer(native) do
    native
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1000)
  end

  defp to_ms(_), do: 0.0
end
