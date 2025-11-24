# BasicBot Example

This sample Mix project shows how to wire SlackBot into an OTP application with:

- middleware + event handlers,
- the slash command grammar DSL with optional/repeat segments,
- diagnostics capture/replay,
- auto-ack strategies (`:ephemeral` + `{:custom, fun}`),
- optional BlockBox helpers (falls back to map builders if not installed).

## Prerequisites

- Slack app configured for Socket Mode with the following tokens:
  - `SLACK_APP_TOKEN` (starts with `xapp-`)
  - `SLACK_BOT_TOKEN` (starts with `xoxb-`)
  - `SLACK_BOT_USER_ID` (bot user ID, used for cache updates)
- Elixir 1.14+, OTP 25+

## Install & Run

```bash
cd examples/basic_bot
mix deps.get

export SLACK_APP_TOKEN="xapp-XXX"
export SLACK_BOT_TOKEN="xoxb-YYY"
export SLACK_BOT_USER_ID="BZZZ"

mix run --no-halt
```

The example depends on the parent repo via `{:slack_bot_ws, path: "../.."}` so you can
modify the library and test behavior immediately.

The example uses the same `otp_app` pattern as the main README:

- `BasicBot.SlackBot` is the SlackBot entrypoint (`use SlackBot, otp_app: :basic_bot`).
- `BasicBot` defines the router with handlers, middleware, and slash grammars.
- `BasicBot.Application` supervises `BasicBot.SlackBot` directly.

## Slash Commands to Try

- `/demo list short fleet tag alpha tag beta`
- `/demo report platform`

The bot also replies to `@mention` events with instructions.

## Diagnostics

Diagnostics are enabled by default (buffer size 200). From `iex -S mix` you can inspect
recent frames or replay them:

```elixir
SlackBot.Diagnostics.list(BasicBot.SlackBot, limit: 5)
SlackBot.Diagnostics.replay(BasicBot.SlackBot)
```

See the top-level `docs/diagnostics.md` for more advanced workflows.

