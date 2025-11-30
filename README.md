# SlackBot (WebSocket)

![SlackBot WS](docs/images/slack_bot_ws_logo.png)

SlackBot is a production-ready Slack bot framework for Elixir built on Socket Mode. It gives you a supervised WebSocket connection, tier-aware rate limiting, deterministic slash-command parsing via a compile-time grammar DSL, and full Telemetry coverage. The event pipeline handles backoff, heartbeats, reconnects, and dedupe so you can focus on your handlers instead of connection management.

### When to use Socket Mode

A WebSocket-based bot is ideal when you want real-time event delivery without exposing a public HTTP endpoint. It excels in environments behind firewalls, on developer laptops, or in architectures where inbound webhooks are undesirable. Persistent connections give you lower-latency interactions, consistent delivery of interactive payloads, and simpler local development. If you want a resilient, stateful channel to Slack that avoids the complexity of managing public callbacks, Socket Mode is the right fit.

## What you get

- A supervised connection that handles backoff, heartbeats, and reconnects so your bot stays online
- Tier-aware rate limiting that respects Slack's published quotas without you writing throttling code
- A compile-time slash-command grammar that turns `/cmd team marketing show` into `%{mode: :team_show, team_name: "marketing"}`
- Pluggable cache and event buffer adapters—ETS handles most workloads on a single node; swap to Redis when you need multi-node redundancy or have external requirements for shared state
- Full Telemetry coverage and an optional diagnostics ring buffer for production debugging
- Sensible defaults: add API tokens, supervise the module, and you have a working bot

> **New to Slack bots?** The [Getting Started guide](docs/getting_started.md) walks through creating a Slack App, enabling Socket Mode, obtaining tokens, and running your first handler.

## Quick Start

### 1. Install

Add SlackBot to your `mix.exs`:

```elixir
def deps do
  [
    {:slack_bot_ws, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

If you have [Igniter](https://hexdocs.pm/igniter) installed, run `mix slack_bot_ws.install` to scaffold a bot module, config, and supervision wiring automatically.

### 2. Define a bot module

```elixir
defmodule MyApp.SlackBot do
  use SlackBot, otp_app: :my_app

  handle_event "message", event, _ctx do
    SlackBot.push({"chat.postMessage", %{
      "channel" => event["channel"],
      "text" => "Hello from MyApp.SlackBot!"
    }})
  end
end
```

**How this works:**

- `use SlackBot, otp_app: :my_app` turns the module into a router that reads configuration from your app's environment and injects the DSL macros (`handle_event`, `slash`, `middleware`).
- `handle_event/3` pattern-matches on Slack event types. The first argument (`"message"`) is the event type to match.
- `event` is the raw payload map from Slack—it contains fields like `"channel"`, `"user"`, `"text"`, and `"ts"` depending on the event type. You destructure what you need.
- `ctx` is the per-event context struct carrying the telemetry prefix, assigns (custom data you configure), and HTTP client. We mark it `_ctx` here because this simple example doesn't use it, but middleware and more complex handlers often pass data through `ctx.assigns`.
- `SlackBot.push/2` sends Web API requests through the managed rate limiter, Telemetry pipeline, and HTTP pool. It returns `{:ok, response}` or `{:error, reason}`.

### 3. Configure tokens

In `config/config.exs`:

```elixir
config :my_app, MyApp.SlackBot,
  app_token: System.fetch_env!("SLACK_APP_TOKEN"),
  bot_token: System.fetch_env!("SLACK_BOT_TOKEN")
```

### 4. Supervise

```elixir
children = [
  MyApp.SlackBot
]

Supervisor.start_link(children, strategy: :one_for_one)
```

That's it. SlackBot boots a Socket Mode connection with ETS-backed cache and event buffer, per-workspace/per-channel rate limiting, and default backoff/heartbeat settings. When you're ready to tune behavior, read on.

## Highlights

- **Supervised connection manager** — WebSocket transport with rate-limit aware backoff, HTTP-based health monitoring (`auth.test` pings), and automatic reconnects
- **Task-based fan-out** — handlers run in supervised tasks so slow commands never block the socket loop
- **Declarative routing** — `handle_event`, `slash`, and `middleware` macros let you compose handlers without sprawling case statements
- **Slash-command grammar DSL** — describe expected syntax declaratively; SlackBot compiles it into a parser at build time (see [Slash Grammar Guide](docs/slash_grammar.md))
- **Pluggable adapters** — swap ETS for Redis when you need cross-node dedupe or shared state
- **Native interactivity routing** — shortcuts, message actions, block suggestions, modal submissions all dispatch through the same pipeline
- **Optional BlockBox integration** — compose Block Kit payloads ergonomically when the dependency is present
- **Telemetry + diagnostics** — connection lifecycle, handler spans, rate/tier limiter decisions, and a ring buffer you can replay in IEx

## Advanced Configuration

Every option below is optional—omit them and SlackBot uses production-ready defaults.

### Connection & backoff

```elixir
config :my_app, MyApp.SlackBot,
  backoff: %{min_ms: 1_000, max_ms: 30_000, max_attempts: :infinity, jitter_ratio: 0.2},
  log_level: :info,
  health_check: [enabled: true, interval_ms: 30_000]
```

### Telemetry

```elixir
config :my_app, MyApp.SlackBot,
  telemetry_prefix: [:slackbot],
  telemetry_stats: [enabled: true, flush_interval_ms: 15_000, ttl_ms: 300_000]
```

When `telemetry_stats` is enabled, `SlackBot.TelemetryStats.snapshot/1` returns rolled-up counters for API calls, handlers, rate/tier limiters, and connection states.

### Cache & event buffer

```elixir
# ETS (default)
cache: {:ets, []}
event_buffer: {:ets, []}

# Redis for multi-node
event_buffer:
  {:adapter, SlackBot.EventBuffer.Adapters.Redis,
   redis: [host: "127.0.0.1", port: 6379], namespace: "slackbot"}
```

### Rate limiting

Per-channel and per-workspace shaping is enabled by default. Disable it only if you're shaping traffic elsewhere:

```elixir
rate_limiter: :none
```

Slack's per-method tier quotas are also enforced automatically. Override entries via the tier registry:

```elixir
config :slack_bot_ws, SlackBot.TierRegistry,
  tiers: %{
    "users.list" => %{max_calls: 10, window_ms: 45_000},
    "users.conversations" => %{group: :metadata_catalog}
  }
```

See [Rate Limiting Guide](docs/rate_limiting.md) for a full explanation of how tier-aware limiting works and how to tune it.

### Slash-command acknowledgements

```elixir
ack_mode: :silent          # default: no placeholder
ack_mode: :ephemeral       # sends "Processing…" via response_url
ack_mode: {:custom, &MyApp.custom_ack/2}
```

### Diagnostics

```elixir
diagnostics: [enabled: true, buffer_size: 300]
```

When enabled, SlackBot captures inbound/outbound frames. See [Diagnostics Guide](docs/diagnostics.md) for IEx workflows and replay.

### Metadata cache & background sync

```elixir
cache_sync: [
  enabled: true,
  kinds: [:channels],       # :users is opt-in
  interval_ms: :timer.hours(1)
]

user_cache: [
  ttl_ms: :timer.hours(1),
  cleanup_interval_ms: :timer.minutes(5)
]
```

## Event Pipeline & Middleware

SlackBot routes events through a Plug-like pipeline. Middleware runs before handlers and can short-circuit with `{:halt, response}`. Multiple `handle_event` clauses for the same type run in declaration order.

```elixir
defmodule MyApp.Router do
  use SlackBot

  defmodule LogMiddleware do
    def call("message", payload, ctx) do
      Logger.debug("incoming: #{payload["text"]}")
      {:cont, payload, ctx}
    end

    def call(_type, payload, ctx), do: {:cont, payload, ctx}
  end

  middleware LogMiddleware

  handle_event "message", payload, ctx do
    Cache.record(payload)
  end

  handle_event "message", payload, ctx do
    Replies.respond(payload, ctx)
  end
end
```

## Slash Command Grammar

The `slash/2` DSL compiles grammar declarations into deterministic parsers:

```elixir
slash "/deploy" do
  grammar do
    value :service
    optional literal("canary", as: :canary?)
    repeat do
      literal "env"
      value :envs
    end
  end

  handle payload, ctx do
    %{service: svc, envs: envs} = payload["parsed"]
    Deployments.kick(svc, envs, ctx)
  end
end
```

| Input | Parsed |
| --- | --- |
| `/deploy api` | `%{service: "api"}` |
| `/deploy api canary env staging env prod` | `%{service: "api", canary?: true, envs: ["staging", "prod"]}` |

See [Slash Grammar Guide](docs/slash_grammar.md) for the full macro reference.

## Web API Helpers

- `SlackBot.push/2` — synchronous; waits for Slack's response
- `SlackBot.push_async/2` — fire-and-forget under the managed Task.Supervisor

Both route through the rate limiter and Telemetry pipeline automatically.

## Diagnostics & Replay

```elixir
iex> SlackBot.Diagnostics.list(MyApp.SlackBot, limit: 5)
[%{direction: :inbound, type: "slash_commands", ...}, ...]

iex> SlackBot.Diagnostics.replay(MyApp.SlackBot, types: ["slash_commands"])
{:ok, 3}
```

Replay feeds events back through your handlers—useful for reproducing production issues locally. See [Diagnostics Guide](docs/diagnostics.md).

## Telemetry & LiveDashboard

SlackBot emits events for connection state, handler execution, rate limiting, and health checks. Integrate with LiveDashboard or attach plain handlers:

```elixir
:telemetry.attach(
  :slackbot_logger,
  [:slackbot, :connection, :state],
  fn _event, _measurements, %{state: state}, _ ->
    Logger.info("Slack connection: #{state}")
  end,
  nil
)
```

See [Telemetry Guide](docs/telemetry_dashboard.md) for metric definitions and LiveDashboard wiring.

## Example Bot

The `examples/basic_bot/` directory contains a runnable project demonstrating:

- slash grammar DSL with optional/repeat segments
- middleware logging
- diagnostics capture and replay
- auto-ack strategies
- optional BlockBox helpers

Follow the README inside that folder to run it against a Slack dev workspace.

## Guides

- [Getting Started](docs/getting_started.md) — from Slack App creation to first slash command
- [Rate Limiting](docs/rate_limiting.md) — how tier-aware limiting works
- [Slash Grammar](docs/slash_grammar.md) — declarative command parsing
- [Diagnostics](docs/diagnostics.md) — ring buffer and replay workflows
- [Telemetry Dashboard](docs/telemetry_dashboard.md) — LiveDashboard integration

## Development

```bash
mix deps.get
mix test
mix format
```

### Test helpers

`SlackBot.TestTransport` and `SlackBot.TestHTTP` in `lib/slack_bot/testing/` let you simulate Socket Mode traffic and stub Web API calls without hitting Slack.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Write tests for your changes
4. Run `mix test` and `mix format`
5. Open a pull request

For larger changes, open an issue first to discuss the approach.

## License

MIT.
