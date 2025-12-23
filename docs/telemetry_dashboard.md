# Telemetry & LiveDashboard Guide

SlackBot emits Telemetry events across its internal systems—connection lifecycle, API calls, rate and tier limiters, handler execution, cache sync, and diagnostics—so you can monitor your bot's health without bolting custom instrumentation onto each handler. This guide shows how to listen to those events and surface them in Phoenix LiveDashboard (or any Telemetry consumer).

## Available Events

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:slackbot, :api, :request]` | `%{duration: native}` | `%{method: String.t(), status: :ok \| :error \| :exception \| :unknown}` |
| `[:slackbot, :api, :rate_limited]` | `%{retry_after_ms: integer, observed_at_ms: integer}` | `%{method: String.t(), key: term()}` |
| `[:slackbot, :connection, :state]` | `%{count: 1}` | `%{state: :connected \| :disconnected \| :terminated \| :down \| :error, reason: term()}` |
| `[:slackbot, :connection, :rate_limited]` | `%{delay_ms: integer}` | `%{}` |
| `[:slackbot, :healthcheck, :ping]` | `%{duration: native}` / `%{delay_ms: integer}` | `%{status: :ok \| :error \| :fatal \| :rate_limited \| :unknown, reason: term()}` |
| `[:slackbot, :healthcheck, :disabled]` | `%{count: 1}` | `%{}` |
| `[:slackbot, :cache, :sync]` | `%{duration: native, count: integer}` | `%{kind: :users \| :channels, status: :ok \| :error}` |
| `[:slackbot, :tier_limiter, :decision]` | `%{count: 1, queue_length: integer, tokens: float}` | `%{method: String.t(), scope_key: term(), decision: :allow \| :queue \| :other}` |
| `[:slackbot, :tier_limiter, :suspend]` | `%{delay_ms: integer}` | `%{method: String.t(), scope_key: term()}` |
| `[:slackbot, :tier_limiter, :resume]` | `%{queue_length: integer, tokens: float}` | `%{method: String.t() \| nil, scope_key: term(), bucket_id: term()}` |
| `[:slackbot, :rate_limiter, :decision]` | `%{queue_length: integer, in_flight: integer}` | `%{key: term(), method: String.t(), decision: :allow \| :queue \| :unknown}` |
| `[:slackbot, :rate_limiter, :blocked]` | `%{delay_ms: integer}` | `%{key: term(), method: String.t()}` |
| `[:slackbot, :rate_limiter, :drain]` | `%{drained: integer, delay_ms: integer \| nil}` | `%{key: term(), reason: term()}` |
| `[:slackbot, :handler, :ingress]` | `%{count: 1}` | `%{decision: :queue \| :duplicate, type: String.t(), envelope_id: String.t() \| nil}` |
| `[:slackbot, :handler, :dispatch, :start/:stop]` (span) | `%{system_time: native}` / `%{duration: native}` | `%{type: event_type, status: :ok \| :error \| :exception \| :halted, envelope_id: String.t() \| nil}` |
| `[:slackbot, :handler, :middleware, :halt]` | `%{count: 1}` | `%{type: String.t(), middleware: String.t(), response: term(), envelope_id: String.t() \| nil}` |
| `[:slackbot, :ack, :http]` | `%{duration: native}` | `%{status: :ok \| :error \| :unknown \| :exception}` |
| `[:slackbot, :diagnostics, :record]` | `%{count: 1}` | `%{direction: :inbound \| :outbound}` |
| `[:slackbot, :diagnostics, :replay]` | `%{count: integer}` | `%{filters: map()}` |
| `[:slackbot, :event_buffer, :record]` | `%{result: :ok \| :duplicate}` | `%{key: String.t() \| nil, result: :ok \| :duplicate}` |
| `[:slackbot, :event_buffer, :delete]` | `%{count: 0 \| 1}` | `%{key: String.t() \| nil, key_present?: boolean()}` |
| `[:slackbot, :event_buffer, :seen]` | `%{count: 1}` | `%{key: String.t() \| nil, seen?: boolean()}` |
| `[:slackbot, :event_buffer, :pending]` | `%{count: integer}` | `%{count: integer}` |

All event names are prefixed with your configured `telemetry_prefix`
(`[:slackbot]` by default), so a handler will actually receive
`[:slackbot, :connection, :state]`, etc.

## Concepts at a Glance

### Rate limiter vs tier limiter

- **Rate limiter** shapes individual Web API calls. It keeps a per-channel bucket for high-volume
  chat methods and a workspace bucket for everything else. A `:decision` event exposes the current
  `queue_length` (pending requests) and `in_flight` count (requests that already passed the gate).
  When Slack replies with `429 Retry-After`, the ETS-backed adapter stores a monotonic
  `blocked_until`, which surfaces as `[:rate_limiter, :blocked]` (with `delay_ms`) and, once the
  timer drains the queue, `[:rate_limiter, :drain]` with the number of releases plus the same delay.
  Track these to understand whether you are pushing against channel-specific chat limits (queue
  spikes) or Slack-imposed cooling-off periods (blocked/drain events).

- **Tier limiter** enforces Slack's published per-method quotas (the "Tier 1-4" buckets). Each method
  (or group) gets a fractional token bucket. `queue_length` indicates how many callers are waiting
  for the window to refill, while `tokens` is the precise number of quota tokens remaining (it is a
  float because Slack quotas are averaged over time). When Slack returns `Retry-After` for a tiered
  method, the limiter suspends that bucket, emits a `:suspend` event with the delay, and later
  emits a corresponding `:resume` when tokens become available again. Use the suspend/resume
  telemetry to answer “which scope is starved right now?”

### Handler pipeline anatomy

- `[:handler, :ingress]` fires for every envelope before the router runs. A `decision` of `:queue`
  means the event entered the pipeline; `:duplicate` indicates the event-buffer dropped a replay.
  Pair it with envelope IDs to reason about dedupe behaviour.

- `[:handler, :dispatch, :stop]` is the Telemetry span that wraps your router. It now carries a
  `status` (`:ok`, `:error`, `:exception`, `:halted`) plus the envelope ID so you can correlate
  slow handlers with specific payloads.

- When a middleware halts the pipeline, SlackBot emits `[:handler, :middleware, :halt]` with the
  middleware module/function and the response returned. This makes it obvious when a safety
  middleware is short-circuiting bursts of traffic.

## Telemetry Stats Cache

SlackBot can maintain a rolling snapshot of the signals above without any external collector. Set

```elixir
config :my_app, MyApp.SlackBot,
  telemetry_stats: [
    enabled: true,
    flush_interval_ms: 15_000,
    ttl_ms: 300_000
  ]
```

When enabled, `SlackBot.TelemetryStats` attaches to your Telemetry prefix, rolls up counters (API
throughput, handler statuses, rate/tier limiter queues, connection states, etc.), and periodically
persists the snapshot to the cache. Because it goes through the cache
adapter, the stats work regardless of whether you are using the default ETS backend or a Redis
adapter.

Read the latest snapshot with:

```elixir
%{
  generated_at_ms: generated,
  expires_at_ms: expires,
  stats: stats
} = SlackBot.TelemetryStats.snapshot(MyApp.SlackBot)

stats.api.total
stats.rate_limiter.last_block_delay_ms
stats.handler.status.halted
```

The map mirrors the structures described above (for example `stats.tier.tokens` keeps the most
recent fractional token value). LiveDashboard, PromEx, or any other Telemetry-aware tooling can
consume this snapshot directly or keep listening to the raw events listed earlier.

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
        unit: :token,
        description: "Tier limiter tokens remaining",
        measurement: :tokens
      ),
      summary(@slackbot_prefix ++ [:handler, :dispatch, :duration],
        unit: {:native, :millisecond},
        description: "Handler execution time"
      ),
      counter(@slackbot_prefix ++ [:handler, :ingress],
        tags: [:decision],
        description: "Ingress decisions (pipeline vs duplicate)"
      ),
      counter(@slackbot_prefix ++ [:handler, :middleware, :halt],
        description: "Middleware short-circuits"
      ),
      last_value(@slackbot_prefix ++ [:rate_limiter, :blocked],
        unit: :millisecond,
        description: "Current rate limiter block delay",
        measurement: :delay_ms
      ),
      counter(@slackbot_prefix ++ [:rate_limiter, :drain],
        description: "Retry-after drains",
        measurement: :drained
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

The sample router in `examples/basic_bot/` includes a `/demo telemetry` command that ships with a
small telemetry probe module. The probe subscribes to the events above, rolls them up in-memory,
and renders the snapshot as a Block Kit card (cache health, API throughput, limiter queues,
connection state, and healthcheck status). It's a practical example of how to consume Telemetry
without Phoenix:

1. The probe calls `:telemetry.attach_many/4` for the SlackBot prefix.
2. It keeps lightweight counters/last-seen metadata in a GenServer.
3. The slash command pulls a snapshot and formats it for Slack.

Feel free to lift that helper into your own bots if you want a prebuilt telemetry "dashboard"
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

---

## Next Steps

- [Getting Started](getting_started.md) — set up a Slack App and run your first handler
- [Rate Limiting](rate_limiting.md) — understand how tier-aware limiting works
- [Slash Grammar](slash_grammar.md) — build deterministic command parsers
- [Diagnostics](diagnostics.md) — capture and replay events for debugging

