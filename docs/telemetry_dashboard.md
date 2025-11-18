# Telemetry & LiveDashboard Guide

SlackBot emits a handful of Telemetry events so you can monitor socket-mode health
without bolting custom instrumentation onto each handler. This guide shows how to listen
to those events and surface them in Phoenix LiveDashboard (or any Telemetry consumer).

## Available Events

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:slackbot, :connection, :state]` | `%{count: 1}` | `%{state: :connected | :disconnected | :terminated | :down | :error, reason: term()}` |
| `[:slackbot, :connection, :heartbeat_timeout]` | `%{count: 1}` | `%{}` |
| `[:slackbot, :connection, :rate_limited]` | `%{delay_ms: integer}` | `%{}` |
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
      counter(@slackbot_prefix ++ [:connection, :heartbeat_timeout],
        description: "Heartbeat timeouts"
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
      summary(@slackbot_prefix ++ [:handler, :dispatch, :duration],
        unit: {:native, :millisecond},
        description: "Handler execution time"
      )
    ]
  end
end
```

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

