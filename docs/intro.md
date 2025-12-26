# SlackBot WS

SlackBot WS (**W**eb**S**ocket) is a production-ready Slack bot framework for Elixir built for Slack's [Socket Mode](https://docs.slack.dev/apis/events-api/using-socket-mode/). It gives you a supervised WebSocket connection, Slack's API tier rate limiting, an elegant slash-command parsing DSL, Plug-like middleware, and comprehensive Telemetry coverage. All the typical side-mission complexity that pulls you away from just building features is eliminated.

Slack's [Socket Mode](https://docs.slack.dev/apis/events-api/using-socket-mode/) shines when you need real-time event delivery without a public HTTP endpoint: laptops, firewalled environments, or stacks where inbound webhooks are undesirable. Persistent connections keep latency low, interactive payloads flowing, and local development simple. Socket Mode is fantastic for internal, private bots within an organization; it's not for Slack's public marketplace, where you'd advertise your application to other Slack organizations.

## Highlights

- **Resilient Socket Mode connection** — supervised transport handles backoff, jittered retries, dedupe, heartbeats, and HTTP-based health checks (`auth.test`) so your bot stays online.
- **Tier-aware rate limiting** — per-channel and per-workspace shaping plus Slack's published tier quotas are enforced automatically; override the registry when you need custom allowances.
- **Deterministic slash-command grammar** — declaratively describe `/deploy api canary` or more complex syntaxes and get structured maps at compile time—no regex piles.
- **Plug-like routing & middleware** — `handle_event`, `slash`, and `middleware` macros let you compose pipelines instead of sprawling case statements.
- **Task-based fan-out** — handlers run in supervised tasks so slow commands never block the socket loop.
- **Native interactivity + BlockBox** — shortcuts, message actions, block suggestions, modal submissions, and optional [BlockBox](https://hex.pm/packages/blockbox) helpers all flow through the same pipeline.
- **Pluggable adapters & cache sync** — ETS cache/event buffer by default; swap to Redis for multi-node, configure cache sync, and set assigns such as `:bot_user_id` for zero-cost membership checks.
- **Observability & diagnostics** — telemetry spans, optional telemetry stats, diagnostics ring buffer with replay, and LiveDashboard-ready metrics.
- **Production defaults out of the box** — add tokens, supervise the module, and you have heartbeats, backoff, and rate limiting without touching config.

> **New to Slack bots?** The [Getting Started guide](getting_started.md) walks through creating a Slack App, enabling Socket Mode, obtaining tokens, and running your first handler.

## See it in action

### Declarative slash commands

```elixir
defmodule MyApp.SlackBot do
  use SlackBot, otp_app: :my_app

  # /deploy api        → %{service: "api"}
  # /deploy api canary → %{service: "api", canary?: true}
  slash "/deploy" do
    value :service
    optional literal("canary", as: :canary?)
    repeat do
      literal "env"
      value :envs
    end

    handle payload, ctx do
      %{service: svc, envs: envs} = payload["parsed"]
      Deployments.kick(svc, envs, ctx)
    end
  end
end
```

| Input | Parsed |
| --- | --- |
| `/deploy api` | `%{service: "api"}` |
| `/deploy api canary env staging env prod` | `%{service: "api", canary?: true, envs: ["staging", "prod"]}` |

See the [Slash Grammar Guide](slash_grammar.md) for the full macro reference.

### Plug-like middleware pipeline

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

### Event handlers + Web API helpers

```elixir
defmodule MyApp.SlackBot do
  use SlackBot, otp_app: :my_app

  handle_event "app_mention", event, _ctx do
    MyApp.SlackBot.push({"chat.postMessage", %{
      "channel" => event["channel"],
      "text" => "Hi <@#{event["user"]}>!"
    }})
  end
end
```

- `MyApp.SlackBot.push/1` is synchronous and waits for Slack's response via the managed HTTP pool, telemetry pipeline, and rate limiter.
- `MyApp.SlackBot.push_async/1` is fire-and-forget under the supervised Task pipeline—perfect for long-running replies or batched API work.

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
    MyApp.SlackBot.push({"chat.postMessage", %{
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
- `MyApp.SlackBot.push/1` sends Web API requests through the managed rate limiter, Telemetry pipeline, and HTTP pool. It returns `{:ok, response}` or `{:error, reason}`.

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

## Multiple bots and instances

The ergonomic path is **one module per bot** using the `otp_app` pattern. Each module gets its own `push/1`, `push_async/1`, `emit/1`, and `config/0` helpers so you always call the right instance:

```elixir
defmodule MyApp.CustomerSuccessBot do
  use SlackBot, otp_app: :my_app
end

defmodule MyApp.IncidentBot do
  use SlackBot, otp_app: :my_app
end

children = [
  MyApp.CustomerSuccessBot,
  MyApp.IncidentBot
]
Supervisor.start_link(children, strategy: :one_for_one)
```

Need distinct runtime instances of the **same** router module (for example, dynamically named bots per workspace)? Start `SlackBot` directly with an explicit `:name` and call the explicit APIs:

```elixir
children = [
  {SlackBot, name: :team_alpha_bot, module: MyApp.DynamicRouter, app_token: ..., bot_token: ...},
  {SlackBot, name: :team_beta_bot, module: MyApp.DynamicRouter, app_token: ..., bot_token: ...}
]

SlackBot.push(:team_alpha_bot, {"chat.postMessage", %{"channel" => "C123", "text" => "hi"}})
```

Avoid mixing the module helpers in this scenario—the helpers assume the supervised process is registered under the module name. Pick one style per instance so the codebase stays predictable.

Background jobs and tooling can also pass a `%SlackBot.Config{}` directly when they already have one on
hand:

```elixir
config = SlackBot.config(MyApp.SlackBot)
SlackBot.emit(config, {"daily_digest", %{"channels" => ["C123"]}})
```

Use this sparingly (for example telemetry probes or test helpers) and prefer the module helpers inside
your application code.

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

SlackBot ships with default specs for every Slack Web API method listed in the published tier tables (including special cases like `chat.postMessage`). Overrides are only necessary when Slack revises quotas or when custom grouping is desired.

See [Rate Limiting Guide](rate_limiting.md) for a full explanation of how tier-aware limiting works and how to tune it.

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

When enabled, SlackBot captures inbound/outbound frames. See [Diagnostics Guide](diagnostics.md) for IEx workflows and replay.

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
  value :service
  optional literal("canary", as: :canary?)
  repeat do
    literal "env"
    value :envs
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

See [Slash Grammar Guide](slash_grammar.md) for the full macro reference.

## Web API Helpers

- `MyApp.SlackBot.push/1` — synchronous; waits for Slack's response
- `MyApp.SlackBot.push_async/1` — fire-and-forget under the managed Task.Supervisor
- `SlackBot.push/2` and `SlackBot.push_async/2` remain available when you need to target a dynamically named instance.

Both variants route through the rate limiter and Telemetry pipeline automatically. Reach for the explicit
`SlackBot.*` forms when you start bots under dynamic names (multi-tenant supervisors, `{:via, ...}` tuples) or
when you're operating on a cached `%SlackBot.Config{}` outside the router (for example a background job or probe).
The module-scoped helpers stay the recommended default for static otp_app bots.

## Diagnostics & Replay

```elixir
iex> SlackBot.Diagnostics.list(MyApp.SlackBot, limit: 5)
[%{direction: :inbound, type: "slash_commands", ...}, ...]

iex> SlackBot.Diagnostics.replay(MyApp.SlackBot, types: ["slash_commands"])
{:ok, 3}
```

Replay feeds events back through your handlers—useful for reproducing production issues locally. See [Diagnostics Guide](diagnostics.md).

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

See [Telemetry Guide](telemetry_dashboard.md) for metric definitions and LiveDashboard wiring.

## Example Bot

The `examples/basic_bot/` directory contains a runnable project demonstrating:

- slash grammar DSL with optional/repeat segments
- middleware logging
- diagnostics capture and replay
- auto-ack strategies
- optional [BlockBox](https://hex.pm/packages/blockbox) helpers

Follow the README inside that folder to run it against a Slack dev workspace.

## Guides

- [Getting Started](getting_started.md) — from Slack App creation to first slash command
- [Rate Limiting](rate_limiting.md) — how tier-aware limiting works
- [Slash Grammar](slash_grammar.md) — declarative command parsing
- [Diagnostics](diagnostics.md) — ring buffer and replay workflows
- [Telemetry Dashboard](telemetry_dashboard.md) — LiveDashboard integration

## Development

```bash
mix deps.get
mix test
mix format
```

### Test helpers

`SlackBot.TestTransport` and `SlackBot.TestHTTP` in `lib/slack_bot/testing/` let you simulate Socket Mode traffic and stub Web API calls without hitting Slack.

### Live Redis tests

`mix test` now exercises the Redis event buffer adapter against a live Redis instance:

- If `REDIS_URL` is unset, the suite attempts to connect to `redis://localhost:6379/0`. When Redis is unavailable, it automatically runs `docker run -d --name slackbot-ws-test-redis -p 6379:6379 redis:7-alpine` and waits for the container to become healthy.
- Provide your own Redis by exporting `REDIS_URL=redis://host:port/db`. When this variable is present the helper will **not** touch Docker; tests will fail fast if the URL is unreachable.
- To stop the auto-managed container manually, run `docker stop slackbot-ws-test-redis`. The helper also removes stale containers before starting new ones and registers an `at_exit` callback so the container stops when the suite finishes.
- GitHub Actions uses the same `REDIS_URL` and runs a dedicated Redis service container, so CI mirrors local behavior.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Write tests for your changes
4. Run `mix test` and `mix format`
5. Open a pull request

For larger changes, open an issue first to discuss the approach.

## License

MIT.
