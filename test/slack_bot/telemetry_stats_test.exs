defmodule SlackBot.TelemetryStatsTest do
  use ExUnit.Case, async: false

  alias SlackBot.TelemetryStats

  setup do
    instance = Module.concat(__MODULE__, Instance)
    prefix = [:telemetry_stats_test, instance]

    config =
      SlackBot.Config.build!(
        app_token: "xapp-stats",
        bot_token: "xoxb-stats",
        module: SlackBot.TestHandler,
        instance_name: instance,
        telemetry_prefix: prefix,
        telemetry_stats: [enabled: true, flush_interval_ms: 50, ttl_ms: 200]
      )

    SlackBot.Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    {:ok, _pid} = start_supervised(TelemetryStats.child_spec(config))

    {:ok, %{config: config}}
  end

  test "aggregates telemetry and stores snapshot in cache", %{config: config} do
    prefix = config.telemetry_prefix
    duration = System.convert_time_unit(2, :millisecond, :native)

    :telemetry.execute(prefix ++ [:api, :request], %{duration: duration}, %{
      status: :ok,
      method: "chat.postMessage"
    })

    :telemetry.execute(prefix ++ [:handler, :dispatch, :stop], %{duration: duration}, %{
      status: :ok
    })

    :telemetry.execute(prefix ++ [:handler, :ingress], %{count: 1}, %{decision: :queue})

    :telemetry.execute(prefix ++ [:rate_limiter, :decision], %{queue_length: 1, in_flight: 1}, %{
      decision: :queue,
      method: "chat.postMessage"
    })

    :telemetry.execute(prefix ++ [:tier_limiter, :decision], %{queue_length: 0, tokens: 2.0}, %{
      decision: :allow,
      method: "users.list",
      scope_key: config.instance_name
    })

    Process.sleep(120)

    snapshot = SlackBot.TelemetryStats.snapshot(config)
    stats = snapshot[:stats] || %{}

    assert get_in(stats, [:api, :total]) == 1
    assert get_in(stats, [:handler, :status, :ok]) == 1
    assert get_in(stats, [:handler, :ingress, :queue]) == 1
    assert get_in(stats, [:rate_limiter, :queue]) == 1
    assert get_in(stats, [:tier, :allow]) == 1
    assert snapshot[:generated_at_ms]
    assert snapshot[:expires_at_ms] > snapshot[:generated_at_ms]
  end
end
