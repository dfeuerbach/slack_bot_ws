# SlackBot

SlackBot is a socket-mode client for building resilient Slack automations in Elixir. It focuses on fast acknowledgements, supervised event handling, NimbleParsec-powered command parsing, and a developer-friendly configuration surface.

## Highlights
- Supervised WebSocket connection manager with rate-limit aware backoff and heartbeat monitoring
- Task-based event fan-out with dedupe and replay safeguards
- Declarative handler DSL for events, slash commands, shortcuts, and middleware
- Slash-command grammar DSL compiled via NimbleParsec for deterministic parsing
- Optional BlockBox integration for composing Block Kit payloads
- Telemetry, structured logging, diagnostics buffers, and replay tooling
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
  assigns: %{bot_user_id: System.get_env("SLACK_BOT_USER_ID")}
```

2. Use the handler DSL to declare events and slash commands:

```elixir
defmodule MyBot do
  use SlackBot

  middleware SlackBot.Middleware.Logger

  handle_event "member_joined_channel", event, ctx do
    SlackBot.Cache.channels(ctx.bot) |> log_join(event["channel"])
  end

  slash "/deploy" do
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

Use `SlackBot.Cache.channels/1` and `SlackBot.Cache.users/1` to inspect cached metadata maintained by the runtime provider/mutation queue pair.

## Slash Command Grammar

The `slash/2` DSL converts structured declarations into NimbleParsec parsers. A few real-world examples:

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

Additional guides (BlockBox helpers, LiveDashboard wiring, examples) will land during later phases.

## Development & Testing
- Install deps: `mix deps.get`
- Run tests: `mix test`
- Format: `mix format`
- Credo/Dialyzer (when configured): `mix credo`, `mix dialyzer`

Use the feature tracker to determine which tests or sample apps should run for a given phase.

## License

MIT. See [LICENSE](LICENSE) for details. Copyright 2025, Douglas Feuerbach.