# SlackBot

![SlackBot WS](docs/images/slackbot_ws_logo.png)

SlackBot is a socket-mode client for building resilient Slack automations in Elixir. It focuses on fast acknowledgements, supervised event handling, deterministic slash-command parsing, and a developer-friendly configuration surface.

## Highlights
- Supervised WebSocket connection manager with rate-limit aware backoff and heartbeat monitoring
- Task-based event fan-out with dedupe and replay safeguards
- Pluggable cache/event buffer adapters (ETS by default, Redis adapter included for multi-node dedupe)
- Declarative handler DSL for events, slash commands, shortcuts, and middleware
- Slash-command grammar DSL that produces deterministic, structured payloads
- Native routing for Slack interactivity payloads (global/message shortcuts, message actions, workflow steps, block suggestions, modal submissions)
- Optional BlockBox integration for composing Block Kit payloads (see [BlockBox docs](https://hexdocs.pm/blockbox/BlockBox.html))
- Live diagnostics ring buffer with replay plus structured logging and Telemetry hooks
- Event buffer + provider/mutation queue caches for dedupe and channel/user snapshots

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

1. Configure your Slack tokens and runtime options (final API subject to change as phases progress):

```elixir
config :slack_bot_ws, SlackBot,
  app_token: System.fetch_env!("SLACK_APP_TOKEN"),
  bot_token: System.fetch_env!("SLACK_BOT_TOKEN"),
  telemetry_prefix: [:slackbot],
  cache: {:ets, []},
  event_buffer: {:ets, []},
  diagnostics: [enabled: true, buffer_size: 300],
  ack_mode: :ephemeral,
  assigns: %{bot_user_id: System.get_env("SLACK_BOT_USER_ID")}
```

> Configuration changes take effect after the `SlackBot` supervisor is restarted.
> Update your config and then restart the supervised bot (for example by
> restarting your application or the specific supervisor branch).

2. Use the handler DSL to declare events and slash commands:

```elixir
defmodule MyBot do
  use SlackBot

  middleware SlackBot.Middleware.Logger

  handle_event "member_joined_channel", event, ctx do
    SlackBot.Cache.channels(ctx.bot) |> log_join(event["channel"])
  end

  # auto-sends an ephemeral "Processing..." ack before heavy work
  slash "/deploy", ack: :ephemeral do
    grammar do
      value :service
      optional literal("short", as: :short?)
      repeat do
        literal "param"
        value :params
      end
    end

    handle payload, ctx do
      parsed = payload["parsed"]
      Deployments.kick(parsed.service, parsed.params, ctx)
    end
  end
end
```

> Existing bots using `handle_slash/3` still work. `payload["parsed"].args` now contains
> the tokenized arguments for those handlers, while the DSL produces structured maps.

Interactive payloads (global shortcuts, message shortcuts, block actions, message actions, workflow step events, block suggestions, modal submissions) are delivered to the router using their native Slack type. Use the regular `handle_event/3` macro or pattern match on the payload:

```elixir
handle_event "shortcut", payload, ctx do
  if payload["callback_id"] == "demo-shortcut" do
    MyApp.handle_shortcut(payload, ctx)
  end
end
```

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
and rate limiting. See [`docs/telemetry_dashboard.md`](docs/telemetry_dashboard.md) for
LiveDashboard metric definitions and examples of attaching plain telemetry handlers when
Phoenix is not available.

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