# SlackBot (WebSocket)

![SlackBot WS](docs/images/slack_bot_ws_logo.png)

SlackBot is a robust, easy-to-use Slack bot framework for Slack's Socket Mode. You get fast and graceful slash-command handling, deterministic command parsing, and a supervised event pipeline that stays responsive under load. Slackbot automatically honors Slack's API Tier-aware rate limits, has built-in cache and metadata sync, replayable diagnostics to ease troubleshooting and full Telemetry coverage. Developers get a clean, composable slash command DSL, first-class interactivity routing, and a runtime designed for survivability and observability.

## Highlights
- Supervised WebSocket connection manager with rate-limit aware backoff, robust HTTP-based health monitoring, and default per-workspace/per-channel Web API rate limiting that follows Slack’s prescribed limits
- Task-based event fan-out with dedupe and replay safeguards
- Pluggable cache/event buffer adapters (ETS by default, Redis adapter included for multi-node dedupe)
- Declarative router DSL for events and shortcuts with first-class middleware (`handle_event`, `middleware`, `slash`, etc.)
- Slash-command grammar DSL that turns raw `/slash` text into deterministic, structured maps (no manual string-splitting)
- Native routing for Slack interactivity payloads (global/message shortcuts, message actions, workflow steps, block suggestions, modal submissions)
- Optional BlockBox integration for composing Block Kit payloads (see [BlockBox docs](https://hexdocs.pm/blockbox/BlockBox.html))
- Cache-backed `SlackBot.TelemetryStats` collector that attaches to all runtime telemetry, rolls up handler/limiter/cache metrics, and exposes a ready-to-use snapshot for LiveDashboard, PromEx, or whatever reporting surface (the example app’s `/demo telemetry` command shows one way to consume it)
- Live diagnostics ring buffer with replay plus structured logging and Telemetry hooks
- Event buffer + provider/mutation queue caches for dedupe and channel/user snapshots
- Read-through user & channel metadata cache (background sync keeps snapshots fresh, helpers fetch
  from Slack on misses so handlers always have current identities and membership)

If you have [Igniter](https://hexdocs.pm/igniter) available in your project, `mix slack_bot_ws.install`
can scaffold a bot module, config, and supervision wiring for you so you can be talking to Slack
in a couple of minutes. The same task will also copy the library’s `AGENTS.md` into your app: it
either appends a **SlackBot** section to your existing `AGENTS.md` or creates/updates
`SLACK_BOT_AGENTS.md` with SlackBot-specific guidance for AI coding agents and other automation.

## Installation

Add SlackBot to your `mix.exs` (replace version with the latest release on Hex):

```elixir
def deps do
  [
    {:slack_bot_ws, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies with:

```bash
mix deps.get
```

## Quick Start

1. Define a bot module using `SlackBot`:

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

**How this works**

- `use SlackBot, otp_app: :my_app` turns the module into a router. At compile time it injects the DSL macros (`handle_event/3`, `slash/2`, etc.) and at runtime SlackBot will look up `MyApp.SlackBot`’s configuration under `:my_app`.
- `handle_event/3` runs for every Slack event whose `"type"` matches the first argument (`"message"` here). The second argument is the raw payload map from Slack, and the third argument (`ctx`) is the per-event context (telemetry prefix, assigns, HTTP client, etc.). We mark it `_ctx` since this example does not need it.
- `SlackBot.push/2` is the safe Web API helper. It automatically routes through the managed rate limiter, telemetry, retries, and Finch pool. Every handler has access to it without additional wiring.

2. Configure your Slack tokens (for example in `config/config.exs`):

```elixir
config :my_app, MyApp.SlackBot,
  app_token: System.fetch_env!("SLACK_APP_TOKEN"),
  bot_token: System.fetch_env!("SLACK_BOT_TOKEN")
```

This wires tokens into `SlackBot.Config`. At runtime SlackBot merges these application env values
with any runtime overrides passed to `SlackBot.start_link/1`, validates them, and stores the result
in the config server so handlers can access immutable settings without re-reading env vars.

3. Supervise your bot alongside your application processes:

```elixir
children = [
  MyApp.SlackBot
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Because the bot module `use`d the OTP integration (`otp_app: :my_app`), each child spec is as simple
as `MyApp.SlackBot`. Under the hood SlackBot supervises Socket Mode transport + cache + rate limiter
processes and resolves the correct configuration by matching the module name.

With just those three pieces (module, config, supervision), SlackBot boots a Socket Mode connection
with sensible defaults for backoff, heartbeats, ETS-backed cache + event buffer, per-workspace/per-channel
Web API rate limiting, telemetry prefix, diagnostics (off by default), and slash-command acknowledgement
strategy. You can refine those via advanced configuration once you are comfortable with the basics.

## Advanced configuration

The configuration surface is deliberately broad, but every option is optional—if you skip this
section, you still get a production-ready baseline. When you are ready to tune behaviour, you can
override any of the following keys under your bot module’s config:

- **Connection & backoff**
  - **`backoff`**: `min_ms`, `max_ms`, `max_attempts`, `jitter_ratio` (controls reconnect timing). Defaults to `min_ms: 1_000`, `max_ms: 30_000`, `max_attempts: :infinity`, `jitter_ratio: 0.2`.
  - **`log_level`**: log verbosity for the connection manager and helpers (defaults to `:info`).
  - **`health_check`**: HTTP-based health pings (`auth.test`) that monitor Slack/Web API reachability and nudge the connection manager to reconnect on repeated network failures. Enabled by default with `interval_ms: 30_000`.

- **Telemetry**
  - **`telemetry_prefix`**: prefix for all Telemetry events (defaults to `[:slackbot]`).
  - **`telemetry_stats`**: Disabled by default. Setting `[enabled: true, flush_interval_ms: 15_000, ttl_ms: 300_000]` turns on the
    cache-backed `SlackBot.TelemetryStats` process. It attaches to the bot’s Telemetry prefix,
    keeps running counters for API calls, handlers, rate/tier limiters, etc., and periodically
    persists a snapshot via the configured cache adapter (ETS, Redis, etc.). Consumers can read
    the rolled-up metrics with `SlackBot.TelemetryStats.snapshot/1` or directly from
    `SlackBot.Cache.metadata/1`. See `docs/telemetry_dashboard.md` for the full field list and
    LiveDashboard wiring.

- **Cache & event buffer**
  - **`cache`**: ETS-backed provider/mutation queues are used by default (`{:ets, []}`). Override only when you need async writes or a custom adapter:

    ```elixir
    cache: {:ets, []}
    cache: {:ets, [mode: :async]}
    cache: {:adapter, MyApp.CacheAdapter, []}
    ```

  - **`event_buffer`**: Also defaults to ETS (`{:ets, []}`) for in-node dedupe. Switch to a custom adapter (Redis included) when you need cross-node coordination:

    ```elixir
    event_buffer: {:ets, []}

    event_buffer:
      {:adapter, SlackBot.EventBuffer.Adapters.Redis,
       redis: [host: "127.0.0.1", port: 6379], namespace: "slackbot"}
    ```

- **Rate limiting**
  - **`rate_limiter`**: per-channel/per-workspace Web API shaping (enabled by default):

    ```elixir
    # default (no explicit config): ETS-backed rate limiter with library defaults

    # disable rate limiting entirely:
    rate_limiter: :none

    # customize adapter options (for example, ETS table name and TTL):
    rate_limiter:
      {:adapter, SlackBot.RateLimiter.Adapters.ETS,
       table: :my_bot_rate_limiter, ttl_ms: 10 * 60_000}
    ```

    When enabled (the default), outbound calls made via `SlackBot.push/2` and `push_async/2`
    are serialized per channel for common chat methods (`chat.postMessage`, `chat.update`,
    `chat.delete`, `chat.scheduleMessage`, `chat.postEphemeral`), with a workspace-level
    key for other methods. Slack `429` responses and `Retry-After` headers drive the
    blocking window so you stay within Slack’s prescribed per-channel and per-workspace
    limits; the ETS adapter is suitable for single-node or per-node shaping, while
    custom adapters can coordinate state across nodes (for example via Redis).

    Slack’s per-method **tier quotas** are also enforced automatically (for example
    `users.list` and `users.conversations` share Tier 2’s “20 per minute” budget so cache
    syncs queue instead of hammering Slack). You can override or extend the tier table via the
    tier registry configuration:

    ```elixir
    config :slack_bot_ws, SlackBot.TierRegistry,
      tiers: %{
        "users.list" => %{max_calls: 10, window_ms: 45_000},
        "users.conversations" => %{group: :metadata_catalog}
      }
    ```

    Each entry supports `:max_calls`, `:window_ms`, `:scope` (`:workspace` or `{:channel, field}`),
    `:group` (to share a token bucket across related methods), optional `:capacity` or `:burst_ratio`
    (additional burst headroom, defaults to 25%), `:initial_fill_ratio` (defaults to 0.5 so new
    buckets start half full), and `:tier` (purely informational). Any method not listed falls back
    to the built-in defaults.

- **Slash-command acknowledgements**
  - **`ack_mode`**: `:silent` (default), `:ephemeral`, or `{:custom, (map(), SlackBot.Config.t() -> any())}`.
    `:silent` avoids sending the “Processing…” placeholder, so slash commands only post their
    final response unless you explicitly opt-in to `:ephemeral` (globally or per command).
  - **`assigns`**: you can set `:slash_ack_text` to customize the ephemeral text and
    `:bot_user_id` to help the cache track channel membership for the bot user.

- **Diagnostics**
  - **`diagnostics`**: Off by default. Enable the ring buffer and set its size:

    ```elixir
    diagnostics: [enabled: true, buffer_size: 300]
    ```

    See `SlackBot.Diagnostics` and `docs/diagnostics.md` for how to list, clear, and replay entries.

- **Metadata cache & background sync**
  - **`cache_sync`**: Refresh cached Slack metadata on a schedule.

    **Defaults:** enabled with `kinds: [:channels]`, so the sync refreshes the channels the bot already belongs to. User sync is opt-in (`kinds: [:users, :channels]` or `[:users]`) and uses the same scheduler.

    ```elixir
    # defaults (channels only)
    config :my_app, MyApp.SlackBot,
      app_token: System.fetch_env!("SLACK_APP_TOKEN"),
      bot_token: System.fetch_env!("SLACK_BOT_TOKEN"),
      cache_sync: [
        enabled: true,
        kinds: [:channels],
        interval_ms: :timer.hours(1)
      ]

    # disable or narrow the sync as needed:
    config :my_app, MyApp.SlackBot,
      cache_sync: [enabled: false]

    config :my_app, MyApp.SlackBot,
      cache_sync: [
        enabled: true,
        kinds: [:users],
        users_conversations_opts: [types: "public_channel,private_channel"]
      ]
    ```

    When channel sync is enabled (the default), SlackBot lists channels via `users.conversations`
    and keeps the cache aligned with the bot’s memberships. The `%SlackBot.Config{user_cache: ...}`
    settings control how long fetched user profiles stick around (one hour TTL by default, with a
    janitor process that clears stale records) once you opt into user sync.

    Your bot helpers (for example `MyApp.find_channel/1`, `MyApp.find_user/1`, and their plural
    counterparts) always read from that cache first. If an entry is missing or expired, the helper
    transparently fetches it from Slack and stores it back so subsequent lookups stay
    in-memory-fast until the TTL elapses again.

    ```elixir
    # customize user cache TTL / cleanup cadence
    config :my_app, MyApp.SlackBot,
      user_cache: [
        ttl_ms: :timer.hours(1),
        cleanup_interval_ms: :timer.minutes(5)
      ]
    ```
    Use `users_conversations_opts` to pass Slack parameters
    like `types`, `limit`, or `exclude_archived` when you need to narrow the sync.

- **Web API pooling**
  - **`api_pool_opts`**: Optional overrides forwarded to Finch for Web API requests (SlackBot uses Finch’s defaults when this key is omitted):

    ```elixir
    api_pool_opts: [
      pools: %{
        default: [size: 20, count: 2]
      }
    ]
    ```

These options can be mixed and matched; anything you omit falls back to the defaults described in
`SlackBot.Config`’s moduledoc.

## Event Pipeline & Middleware

SlackBot routes every non-slash event through a Plug-like pipeline:

1. Each middleware (declared via `middleware/1`) receives `{type, payload, ctx}` and decides whether to continue (`{:cont, new_payload, new_ctx}`) or short-circuit (`{:halt, response}`).
2. Every `handle_event` definition matching the event type runs in declaration order, letting you layer responsibilities (logging, ACL checks, cache updates, business logic) without cramming them into one function.

```elixir
defmodule LayeredRouter do
  use SlackBot

  require Logger

  defmodule LogMiddleware do
    def call("message", payload, ctx) do
    Logger.debug("incoming=#{payload["text"]}")
    {:cont, payload, ctx}
  end

    def call(_type, payload, ctx), do: {:cont, payload, ctx}
  end

  defmodule BlocklistMiddleware do
    def call("message", payload, ctx) do
    if payload["user"] in ctx.assigns.blocked_users do
      {:halt, {:error, :blocked}}
    else
      {:cont, payload, ctx}
    end
  end

    def call(_type, payload, ctx), do: {:cont, payload, ctx}
  end

  middleware LogMiddleware
  middleware BlocklistMiddleware

  handle_event "message", payload, ctx do
    Cache.record_message(ctx.assigns.tenant_id, payload)
  end

  handle_event "message", payload, ctx do
    Replies.respond(payload, ctx)
  end
end
```

**What’s happening above**

1. The `middleware` calls register Logger/blocklist modules whose `call/3` functions run before every handler. Each receives `{type, payload, ctx}` and must return `{:cont, payload, ctx}` to continue or `{:halt, response}` to short-circuit.
2. `ctx.assigns` is the per-request map you configure via `assigns:`. It carries things like `blocked_users` and `tenant_id` so middleware and handlers can share state without globals.
3. Both `handle_event "message", ...` clauses fire for every message envelope, in the order they appear. That keeps caching and replying isolated while sharing the same event stream.

In this example the cache update and reply logic stay isolated, yet both run for each message.
Because middleware runs before every handler, the block list can short-circuit the pipeline
(`{:halt, ...}`) and stop every remaining handler. Slash commands keep their single match
semantics so only the grammar that owns `/cmd` fires.

Middleware modules can be defined inline (as above) or referenced as fully-qualified modules.
Anonymous middleware is intentionally unsupported so the pipeline remains deterministic and
introspectable.

3. Supervise SlackBot alongside your application processes:

```elixir
children = [
  {SlackBot,
   name: MyBot.SlackBot,
   app_token: System.fetch_env!("SLACK_APP_TOKEN"),
   bot_token: System.fetch_env!("SLACK_BOT_TOKEN"),
   module: MyBot}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Use `SlackBot.Cache.channels/1`, `SlackBot.Cache.users/1`, and `SlackBot.Cache.metadata/1` to inspect cached state maintained by the runtime provider/mutation queue pair.

## Adapters & Multi-node Deployments

Both the cache and event buffer accept custom adapters so you can share state across BEAM nodes or move metadata into Redis:

```elixir
config :slack_bot_ws, SlackBot,
  cache: {:adapter, SlackBot.Cache.Adapters.ETS, []},
  event_buffer:
    {:adapter, SlackBot.EventBuffer.Adapters.Redis,
     redis: [host: "127.0.0.1", port: 6379], namespace: "slackbot"}
```

- The built-in ETS cache adapter keeps the original provider/mutation queue semantics for single-node deployments. Supply `cache: {:ets, [mode: :async]}` if you prefer fire-and-forget writes that never block the socket.
- `SlackBot.EventBuffer.Adapters.Redis` ships with the toolkit and uses `Redix` under the hood; pass your own options or wrap the behaviour to integrate alternative datastores.
- Implement `SlackBot.Cache.Adapter` / `SlackBot.EventBuffer.Adapter` to plug in any backend—tests demonstrate lightweight adapters for reference.

## Example Bot

The `examples/basic_bot/` directory contains a runnable Mix project that demonstrates:

- the slash grammar DSL (optional/repeat segments),
- middleware for logging,
- diagnostics capture + replay from IEx,
- auto-ack strategies (`:ephemeral`, `{:custom, fun}`),
- optional BlockBox helpers (with graceful fallback if the dependency is absent).

Follow the README inside that folder to run the example against a Slack dev workspace (it
uses a path dependency pointing at this repo).

## Web API helpers

- `SlackBot.push/2` remains synchronous when you want to await the response.
- `SlackBot.push_async/2` runs requests under the managed `Task.Supervisor`, keeping handlers responsive while telemetry + retries still flow through the same pipeline.

SlackBot supervises a dedicated Finch pool (named `MyBot.SlackBot.APIFinch`) for all Slack Web
API requests issued through `SlackBot.push/2`. Tune the pool using `:api_pool_opts`:

```elixir
config :slack_bot_ws, SlackBot,
  api_pool_opts: [
    pools: %{
      default: [size: 20, count: 2]
    }
  ]
```

Increase `size`/`count` for burstier workloads, or lower them when you have a single bot with
modest Web API traffic.

## Diagnostics & Replay

Enable diagnostics in your config to keep a rolling buffer of inbound/outbound frames:

```elixir
config :slack_bot_ws, SlackBot, diagnostics: [enabled: true, buffer_size: 300]
```

> Diagnostics buffers store full Slack payloads (including user text). Enable them only in
> environments where retaining that data is acceptable, and clear the buffer when you no
> longer need the captured events.

From `iex -S mix`, you can inspect or replay traffic without waiting for Slack to resend:

```elixir
iex> SlackBot.Diagnostics.list(MyBot.SlackBot, limit: 5)
[%{direction: :inbound, type: "slash_commands", ...}, ...]

iex> SlackBot.Diagnostics.replay(MyBot.SlackBot, types: ["slash_commands"])
{:ok, 3}
```

Replay feeds events back through `SlackBot.emit/2`, so handlers, middleware, caches, and
telemetry fire exactly as they did originally. For tests, pass `dispatch: fn entry -> ... end`
to intercept the replay without touching the live connection. See
[`docs/diagnostics.md`](docs/diagnostics.md) for advanced workflows.

## Telemetry & LiveDashboard

SlackBot emits Telemetry events for connection state, handler spans, diagnostics record/replay,
rate limiting, and HTTP-based health checks (via `[:slackbot, :healthcheck, :ping]`). See
[`docs/telemetry_dashboard.md`](docs/telemetry_dashboard.md) for LiveDashboard metric definitions
and examples of attaching plain telemetry handlers when Phoenix is not available.

## Slash Command Grammar

The `slash/2` DSL converts structured declarations into deterministic parsers (no manual string splitting required). A few real-world examples:

| Slack Input | DSL snippet | Handler payload |
| --- | --- | --- |
| `/cmd project report` | `literal "project", as: :mode, value: :project_report`<br>`literal "report"` | `%{command: "cmd", mode: :project_report}` |
| `/cmd team marketing show` | `literal "team", as: :mode, value: :team_show`<br>`value :team_name`<br>`literal "show"` | `%{command: "cmd", mode: :team_show, team_name: "marketing"}` |
| `/cmd report team one team two team three` | `literal "report", as: :mode, value: :report_teams`<br>`repeat do literal "team"; value :teams end` | `%{command: "cmd", mode: :report_teams, teams: ["one","two","three"]}` |

See [`docs/slash_grammar.md`](docs/slash_grammar.md) for the full macro reference and more examples.

## Documentation
- `docs/slackbot_design.md` – system design, goals, and architecture
- `docs/feature_tracker.md` – phased implementation plan
- `docs/slash_grammar.md` – comprehensive slash-command DSL guide
- `docs/diagnostics.md` – diagnostics buffer + replay guide
- `docs/telemetry_dashboard.md` – Telemetry + LiveDashboard integration

Additional guides (BlockBox helpers, LiveDashboard wiring, examples) will land during later phases.

## Development & Testing
- Install deps: `mix deps.get`
- Run tests: `mix test`
- Format: `mix format`
- Credo/Dialyzer (when configured): `mix credo`, `mix dialyzer`

Use the feature tracker to determine which tests or sample apps should run for a given phase.

### Test helpers

`SlackBot.TestTransport` and `SlackBot.TestHTTP` are packaged under `lib/slack_bot/testing/` for reuse. Point your config at the transport to simulate Socket Mode traffic or inject the HTTP client when exercising `SlackBot.push/2` in isolation.

## License

MIT. See [LICENSE](https://github.com/dfeuerbach/slack_bot_ws/blob/master/LICENSE) for details. Copyright 2025, Douglas Feuerbach.