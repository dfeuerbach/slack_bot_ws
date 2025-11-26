# SlackBot

![SlackBot WS](docs/images/slackbot_ws_logo.png)

SlackBot is a Socket Mode toolkit for building resilient Slack bots in Elixir. It focuses on fast slash-command acknowledgements, supervised event handling, deterministic command parsing, and a configuration surface that stays simple for single bots while scaling to multi-bot, multi-node deployments.

## Highlights
- Supervised WebSocket connection manager with rate-limit aware backoff, robust HTTP-based health monitoring, and default per-workspace/per-channel Web API rate limiting that follows Slack’s prescribed limits
- Task-based event fan-out with dedupe and replay safeguards
- Pluggable cache/event buffer adapters (ETS by default, Redis adapter included for multi-node dedupe)
- Declarative router DSL for events and shortcuts with first-class middleware (`handle_event`, `middleware`, `slash`, etc.)
- Slash-command grammar DSL that turns raw `/slash` text into deterministic, structured maps (no manual string-splitting)
- Native routing for Slack interactivity payloads (global/message shortcuts, message actions, workflow steps, block suggestions, modal submissions)
- Optional BlockBox integration for composing Block Kit payloads (see [BlockBox docs](https://hexdocs.pm/blockbox/BlockBox.html))
- Live diagnostics ring buffer with replay plus structured logging and Telemetry hooks
- Event buffer + provider/mutation queue caches for dedupe and channel/user snapshots

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

2. Configure your Slack tokens (for example in `config/config.exs`):

```elixir
config :my_app, MyApp.SlackBot,
  app_token: System.fetch_env!("SLACK_APP_TOKEN"),
  bot_token: System.fetch_env!("SLACK_BOT_TOKEN")
```

3. Supervise your bot alongside your application processes:

```elixir
children = [
  MyApp.SlackBot
]

Supervisor.start_link(children, strategy: :one_for_one)
```

With just those three pieces (module, config, supervision), SlackBot boots a Socket Mode connection
with sensible defaults for backoff, heartbeats, ETS-backed cache + event buffer, per-workspace/per-channel
Web API rate limiting, telemetry prefix, diagnostics (off by default), and slash-command acknowledgement
strategy. You can refine those via advanced configuration once you are comfortable with the basics.

## Advanced configuration

The configuration surface is deliberately broad, but every option is optional—if you skip this
section, you still get a production-ready baseline. When you are ready to tune behaviour, you can
override any of the following keys under your bot module’s config:

- **Connection & backoff**
  - **`backoff`**: `min_ms`, `max_ms`, `max_attempts`, `jitter_ratio` (controls reconnect timing).
  - **`log_level`**: log verbosity for the connection manager and helpers.
  - **`health_check`**: HTTP-based health pings (`auth.test`) that monitor Slack/Web API reachability and nudge the connection manager to reconnect on repeated network failures.

- **Telemetry**
  - **`telemetry_prefix`**: prefix for all Telemetry events (defaults to `[:slackbot]`).

- **Cache & event buffer**
  - **`cache`**: choose ETS or a custom adapter:

    ```elixir
    cache: {:ets, []}
    cache: {:ets, [mode: :async]}
    cache: {:adapter, MyApp.CacheAdapter, []}
    ```

  - **`event_buffer`**: choose ETS or a custom adapter (Redis adapter included):

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

- **Slash-command acknowledgements**
  - **`ack_mode`**: `:silent` (default), `:ephemeral`, or `{:custom, (map(), SlackBot.Config.t() -> any())}`.
  - **`assigns`**: you can set `:slash_ack_text` to customize the ephemeral text and
    `:bot_user_id` to help the cache track channel membership for the bot user.

- **Diagnostics**
  - **`diagnostics`**: enable the ring buffer and set its size:

    ```elixir
    diagnostics: [enabled: true, buffer_size: 300]
    ```

    See `SlackBot.Diagnostics` and `docs/diagnostics.md` for how to list, clear, and replay entries.

- **Web API pooling**
  - **`api_pool_opts`**: forwarded to Finch for Web API requests:

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

- `SlackBot.Cache.Adapters.ETS` keeps the original provider/mutation queue semantics for single-node deployments. Supply `cache: {:ets, [mode: :async]}` if you prefer fire-and-forget writes that never block the socket.
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

MIT. See [LICENSE](LICENSE) for details. Copyright 2025, Douglas Feuerbach.