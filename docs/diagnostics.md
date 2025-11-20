# Diagnostics & Replay Guide

SlackBot ships with first-class diagnostics so you can inspect and replay recent
Socket Mode activity without begging Slack to resend events. Enable diagnostics in
your runtime config and use the APIs below from `iex`, remote consoles, or tests.

## Enabling Diagnostics

```elixir
config :slack_bot_ws, SlackBot,
  app_token: "...",
  bot_token: "...",
  module: MyBot,
  diagnostics: [enabled: true, buffer_size: 300]
```

- `enabled` — turn capture on/off (default: `false`).
- `buffer_size` — maximum number of frames kept per instance (default: `200`).

Diagnostics buffers live per SlackBot instance (derived from the supervisor name).

## Capturing Events Automatically

When enabled, SlackBot records:

- **Inbound frames** after dedupe: event type, payload, and envelope metadata.
- **Synthetic events** triggered via `SlackBot.emit/2`.
- **Outgoing frames** emitted through `SlackBot.Socket` (handy for debugging ack flows).

Every entry includes timestamp, direction, type, and payload snapshot.

## Inspecting the Buffer in IEx

```elixir
iex> SlackBot.Diagnostics.list(MyBot.SlackBot)
[
  %{direction: :inbound, type: "slash_commands", at: ~U[2025-05-01 17:30:33Z], ...},
  %{direction: :inbound, type: "message", at: ~U[2025-05-01 17:30:31Z], ...}
]

iex> SlackBot.Diagnostics.list(MyBot.SlackBot, limit: 1, direction: :outbound)
[%{direction: :outbound, type: "ack", ...}]

iex> SlackBot.Diagnostics.clear(MyBot.SlackBot)
:ok
```

Filtering options (also accepted when you pass the `%SlackBot.Config{}` struct directly):

- `:direction` — `:inbound | :outbound | :both` (default: `:both`).
- `:types` — string or list of event types (`"message"`, `"slash_commands"`, etc.).
- `:limit` — cap the number of entries returned (defaults to buffer size).
- `:dispatch` — optional callback (primarily for tests) invoked during `replay/2` instead
  of calling `SlackBot.emit/2`.

## Replaying Events

Replay re-feeds captured inbound events through the handler pipeline; perfect for
reproducing a production issue locally or in QA.

```elixir
iex> SlackBot.Diagnostics.replay(MyBot.SlackBot, types: ["slash_commands"])
{:ok, 3}
```

- Events are replayed newest-to-oldest unless you pass `:order => :oldest_first`.
- SlackBot uses `SlackBot.emit/2` under the hood, so middleware, caches, and
  handler instrumentation all run exactly as if Slack sent the events again.

### Example Debugging Workflow

1. Enable diagnostics in production and deploy/restart the bot so the new config takes effect.
2. When an incident occurs, open a remote IEx session:
   ```elixir
   :rpc.call(node, SlackBot.Diagnostics, :list, [MyBot.SlackBot, [types: ["slash_commands"]]])
   ```
3. Save the interesting entries (or `:rpc.call` `SlackBot.Diagnostics.replay/2` on a staging node).
4. Replay locally to reproduce the problem in tests. You can also override the dispatch
   target during tests with `dispatch: fn entry -> ... end`.

## Telemetry & Logging

Diagnostics actions emit Telemetry events (prefixed by `telemetry_prefix`):

- `[:slackbot, :diagnostics, :record]` — measurements: `%{count: 1}`; metadata: `%{direction: :inbound}`
- `[:slackbot, :diagnostics, :replay]` — metadata includes replay count and filter options.

Combine them with the structured logging helpers (`SlackBot.Logging.with_envelope/3`)
to correlate payload metadata with your application logs. Example metric:

```elixir
Summary.new(
  [:slackbot, :diagnostics, :replay],
  unit: :event,
  tags: [:instance],
  measurement: :count
)
```

## Safety Considerations

- Buffers contain raw payloads (user content). Scrub before copying outside secure
  environments.
- Disable diagnostics in environments where sensitive data must not linger in memory.
- Use `SlackBot.Diagnostics.clear/1` after you capture what you need.

