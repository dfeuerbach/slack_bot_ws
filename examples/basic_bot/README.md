# BasicBot Example

This sample Mix project shows how to wire SlackBot into an OTP application with:

- middleware + event handlers,
- the slash command grammar DSL with optional/repeat segments,
- diagnostics capture/replay,
- auto-ack strategies (`:ephemeral` + `{:custom, fun}`),
- optional BlockBox helpers (falls back to map builders if not installed),
- explicit ephemeral messaging and async Web API usage,
- robust connection health monitoring and automatic reconnects via the library’s HTTP-based health checks.

## Prerequisites

- Slack app configured for Socket Mode with the following tokens:
  - `SLACK_APP_TOKEN` (starts with `xapp-`)
  - `SLACK_BOT_TOKEN` (starts with `xoxb-`)
- Elixir 1.14+, OTP 25+

## Install & Run

```bash
cd examples/basic_bot
mix deps.get

export SLACK_APP_TOKEN="xapp-XXX"
export SLACK_BOT_TOKEN="xoxb-YYY"

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
- `/demo blocks`
- `/demo ping-ephemeral`
- `/demo async-demo`

When the bot is in a channel:

- Mention it with `@basic-bot` (or your app's bot handle) to get a quick help message.
- Run `/demo blocks` to see a Block Kit message; if BlockBox is installed and configured, it
  will use BlockBox to build the blocks, otherwise it falls back to map helpers.
- Run `/demo ping-ephemeral` to see an ephemeral message that only you can see.
- Run `/demo async-demo` to see a short series of async messages followed by a final summary.

The bot also replies to `@mention` events with instructions.

## Diagnostics

Diagnostics are enabled by default (buffer size 200). From `iex -S mix` you can inspect
recent frames or replay them:

```elixir
SlackBot.Diagnostics.list(BasicBot.SlackBot, limit: 5)
SlackBot.Diagnostics.replay(BasicBot.SlackBot)
```

See the top-level `docs/diagnostics.md` for more advanced workflows.

