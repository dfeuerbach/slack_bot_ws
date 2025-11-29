# Telemetry & LiveDashboard Guide

SlackBot emits a handful of Telemetry events so you can monitor socket-mode health
without bolting custom instrumentation onto each handler. This guide shows how to listen
to those events and surface them in Phoenix LiveDashboard (or any Telemetry consumer).

## Available Events

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:slackbot, :api, :request]` | `%{duration: native}` | `%{method: String.t(), status: :ok | :error | :exception}` |
| `[:slackbot, :api, :rate_limited]` | `%{retry_after_ms: integer, observed_at_ms: integer}` | `%{method: String.t(), key: term()}` |
| `[:slackbot, :connection, :state]` | `%{count: 1}` | `%{state: :connected | :disconnected | :terminated | :down | :error, reason: term()}` |
| `[:slackbot, :connection, :rate_limited]` | `%{delay_ms: integer}` | `%{}` |
| `[:slackbot, :healthcheck, :ping]` | `%{duration: native}` / `%{delay_ms: integer}` | `%{status: :ok | :error | :fatal | :rate_limited | :unknown, reason: term()}` |
| `[:slackbot, :healthcheck, :disabled]` | `%{count: 1}` | `%{}` |
| `[:slackbot, :cache, :sync]` | `%{duration: native, count: integer}` | `%{kind: :users | :channels, status: :ok | :error}` |
| `[:slackbot, :tier_limiter, :decision]` | `%{count: 1, queue_length: integer}` | `%{method: String.t(), scope_key: term(), decision: :allow | :queue}` |
| `[:slackbot, :rate_limiter, :decision]` | `%{queue_length: integer, in_flight: integer}` | `%{key: term(), method: String.t(), decision: :allow | :queue | :unknown}` |
| `[:slackbot, :rate_limiter, :drain]` | `%{drained: integer}` | `%{key: term(), reason: term()}` |
| `[:slackbot, :ack, :http]` | `%{duration: native}` | `%{status: :ok | :error | :unknown | :exception}` |
| `[:slackbot, :handler, :dispatch, :start/:stop]` (Telemetry span) | `%{system_time: native}` | `%{type: event_type}` |
| `[:slackbot, :diagnostics, :record]` | `%{count: 1}` | `%{direction: :inbound | :outbound}` |
| `[:slackbot, :diagnostics, :replay]` | `%{count: integer}` | `%{filters: map()}` |

All event names are prefixed with your configured `telemetry_prefix`
(`[:slackbot]` by default), so a handler will actually receive
`[:slackbot, :connection, :state]`, etc.

## Wiring LiveDashboard Metrics

If you already use Phoenix LiveDashboard, add the metrics below to the module where you
define your dashboard metrics (often `MyAppWeb.Telemetry`). The only requirement is
having `Telemetry.Metrics` in your deps (Phoenix generators include it by default).

```elixir
defmodule MyAppWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  @slackbot_prefix [:slackbot]

  def metrics do
    [
      counter(@slackbot_prefix ++ [:connection, :state],
        tags: [:state],
        description: "Connection state transitions"
      ),
      counter(@slackbot_prefix ++ [:healthcheck, :ping],
        tags: [:status],
        description: "Slack healthcheck pings by status"
      ),
      last_value(@slackbot_prefix ++ [:connection, :rate_limited],
        unit: :millisecond,
        description: "Slack backoff delay when rate limited",
        measurement: :delay_ms
      ),
      summary(@slackbot_prefix ++ [:diagnostics, :replay],
        unit: :event,
        description: "Diagnostics replays issued",
        measurement: :count
      ),
      counter(@slackbot_prefix ++ [:tier_limiter, :decision],
        tags: [:method, :decision],
        description: "Tier limiter decisions by API method"
      ),
      last_value(@slackbot_prefix ++ [:tier_limiter, :decision],
        unit: :event,
        description: "Tier limiter queue length",
        measurement: :queue_length
      ),
      summary(@slackbot_prefix ++ [:handler, :dispatch, :duration],
        unit: {:native, :millisecond},
        description: "Handler execution time"
      )
    ]
  end
end
```

The tier limiter metrics let you spot when Slack’s published quotas are nearing their cap.
`queue_length` spikes mean requests are waiting for the bucket to refill, and you can drill
into the tagged `decision` counter to see which methods are being throttled.

> **Note:** Telemetry spans emit `:start`/`:stop` events. Phoenix LiveDashboard expects a
> `summary` metric built from the `:stop` event where `measurement: :duration`. The
> helper above covers that pattern.

Once the metrics function returns these entries, expose them in `router.ex` (if you have
LiveDashboard enabled):

```elixir
live_dashboard "/dashboard",
  metrics: MyAppWeb.Telemetry
```

## Consuming Events Without Phoenix

You can always attach your own handlers if you don’t have Phoenix at all:

```elixir
:telemetry.attach(
  {:slackbot_logger, self()},
  [:slackbot, :connection, :state],
  fn _event, _measurements, %{state: state}, _ ->
    Logger.info("Slack connection state changed: #{state}")
  end,
  nil
)
```

Because SlackBot uses standard Telemetry primitives, any tool that understands Telemetry
events (StatsD exporters, OpenTelemetry bridges, etc.) will work out of the box.

## Sample Snapshot (`/demo telemetry`)

The sample router in `examples/basic_bot/` includes a `/demo telemetry` command that uses
`BasicBot.TelemetryProbe` to subscribe to the events above, roll them up in-memory, and render
the snapshot as a Block Kit card (cache health, API throughput, limiter queues, connection state,
and healthcheck status). It’s a practical example of how to consume Telemetry without Phoenix:

1. `BasicBot.TelemetryProbe` calls `:telemetry.attach_many/4` for the SlackBot prefix.
2. It keeps lightweight counters/last-seen metadata in a GenServer.
3. The slash command pulls a snapshot and formats it for Slack.

Feel free to lift that module into your own bots if you want a prebuilt telemetry “dashboard”
inside Slack itself.

## Exposing Diagnostics in LiveDashboard

Pair Telemetry metrics with diagnostics replay for a richer debugging workflow:

1. Enable diagnostics in your config:
   ```elixir
   config :slack_bot_ws, SlackBot,
     diagnostics: [enabled: true, buffer_size: 300]
   ```
2. Add a custom LiveDashboard page or a Phoenix route that calls
   `SlackBot.Diagnostics.list/2` and renders the recent frames.
3. Provide a button that hits an endpoint wired to `SlackBot.Diagnostics.replay/2`.

Because diagnostics stores payloads in ETS via a supervised GenServer, calling those
functions does not block the main Slack connection.

## Summary

- Telemetry events cover connection lifecycle, handler spans, and diagnostics activities.
- LiveDashboard can plot these metrics with a few lines of `Telemetry.Metrics`.
- Diagnostics replays + Telemetry metrics offer a full picture when debugging Slack bots
  in production.

