defmodule BasicBotTelemetryTest do
  use ExUnit.Case, async: false

  alias BasicBot.TelemetryProbe

  setup_all do
    start_supervised!({BasicBot.TelemetryProbe, [bot: BasicBot.SlackBot]})
    :ok
  end

  setup do
    TelemetryProbe.reset(BasicBot.SlackBot)
    :ok
  end

  test "aggregates telemetry events into a snapshot" do
    prefix = telemetry_prefix()

    :telemetry.execute(prefix ++ [:api, :request], %{duration: 1_000_000}, %{status: :ok})

    :telemetry.execute(
      prefix ++ [:api, :rate_limited],
      %{retry_after_ms: 500, observed_at_ms: 0},
      %{
        method: "chat.postMessage",
        key: :workspace
      }
    )

    :telemetry.execute(prefix ++ [:tier_limiter, :decision], %{count: 1, queue_length: 3}, %{
      method: "users.list",
      scope_key: :workspace,
      decision: :queue
    })

    :telemetry.execute(prefix ++ [:rate_limiter, :decision], %{queue_length: 2, in_flight: 1}, %{
      method: "chat.postMessage",
      decision: :queue
    })

    :telemetry.execute(prefix ++ [:cache, :sync], %{duration: 2_000_000, count: 42}, %{
      kind: :users,
      status: :ok
    })

    :telemetry.execute(prefix ++ [:connection, :state], %{count: 1}, %{state: :connected})
    :telemetry.execute(prefix ++ [:healthcheck, :ping], %{duration: 500_000}, %{status: :ok})
    :telemetry.execute(prefix ++ [:ack, :http], %{duration: 100_000}, %{status: :ok})

    snapshot = TelemetryProbe.snapshot(BasicBot.SlackBot)

    assert snapshot.api.total == 1
    assert snapshot.api.rate_limited == 1
    assert snapshot.tier.queue == 1
    assert snapshot.rate_limiter.queue == 1
    assert snapshot.cache.last_sync_kind == :users
    assert snapshot.connection.states[:connected] == 1
  end

  test "telemetry blocks render key metrics" do
    snapshot = %{
      generated_at: DateTime.utc_now(),
      cache: %{
        users: 5,
        channels: 3,
        last_sync_kind: :users,
        last_sync_status: :ok,
        last_sync_count: 20,
        last_sync_duration_ms: 12.5
      },
      api: %{total: 10, ok: 9, error: 1, unknown: 0, avg_duration_ms: 15.2, rate_limited: 2},
      tier: %{allow: 5, queue: 3, other: 0, last_queue: 2, busiest: {"users.list", 4}},
      rate_limiter: %{allow: 7, queue: 1, other: 0, drains: 2, last_queue: 1},
      connection: %{states: %{connected: 3}, last_state: :connected, rate_limited: 0},
      health: %{last_status: :ok, failures: 0, disabled: false},
      ack: %{ok: 5, error: 0, unknown: 0}
    }

    blocks = BasicBot.telemetry_blocks(snapshot)

    assert length(blocks) >= 5

    assert List.first(blocks)["text"]["text"] == "*Runtime telemetry snapshot*"
  end

  defp telemetry_prefix, do: [:slackbot]
end
