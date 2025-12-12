# BasicBot Example

A runnable Slack bot demonstrating SlackBot's key features. Use this as a reference when building your own bot.

## What This Example Shows

- **Event handlers and middleware** — layered processing with `handle_event` and `middleware`
- **Slash command grammar DSL** — `optional`, `repeat`, and `choice` segments parsed at compile time
- **Diagnostics capture/replay** — inspect and replay recent events from IEx
- **Auto-ack strategies** — `:ephemeral` and `{:custom, fun}` acknowledgements
- **Telemetry stats aggregator** — `/demo telemetry` renders a Block Kit card with live metrics
- **Rate limiting** — per-channel and tier-aware limiting enabled by default
- **Optional BlockBox helpers** — graceful fallback to map builders when BlockBox isn't installed

## Prerequisites

- A Slack App configured for Socket Mode (see [Getting Started Guide](../../docs/getting_started.md))
  - `SLACK_APP_TOKEN` (starts with `xapp-`)
  - `SLACK_BOT_TOKEN` (starts with `xoxb-`)
- Elixir 1.17+, OTP 27+

## Install & Run

```bash
cd examples/basic_bot
mix deps.get

export SLACK_APP_TOKEN="xapp-..."
export SLACK_BOT_TOKEN="xoxb-..."

iex -S mix
```

The example depends on the parent repo via `{:slack_bot_ws, path: "../.."}` so you can modify the library and test behavior immediately.

## Project Structure

| File | Purpose |
|------|---------|
| `lib/basic_bot/slack_bot.ex` | SlackBot entrypoint (`use SlackBot, otp_app: :basic_bot`) |
| `lib/basic_bot.ex` | Router with handlers, middleware, and slash grammars |
| `lib/basic_bot/application.ex` | Supervises `BasicBot.SlackBot` |
| `lib/basic_bot/telemetry_probe.ex` | Lightweight Telemetry handler for `/demo telemetry` |
| `config/config.exs` | Tokens, diagnostics, and telemetry_stats configuration |

## Slash Commands to Try

| Command | What It Does |
|---------|--------------|
| `/demo list short fleet tag alpha tag beta` | Grammar with `optional` and `repeat` |
| `/demo report platform` | Simple literal + value grammar |
| `/demo blocks` | Block Kit message (uses BlockBox if available) |
| `/demo ping-ephemeral` | Ephemeral message visible only to you |
| `/demo async-demo` | Async messages via `push_async/2` |
| `/demo users` | Lists cached users |
| `/demo channels` | Lists cached channels |
| `/demo telemetry` | Renders live metrics as a Block Kit card |

## Telemetry Snapshot

The `/demo telemetry` command demonstrates `SlackBot.TelemetryStats.snapshot/1`. The rendered card shows:

- **Cache** — user/channel counts, most recent sync (kind, status, records, duration)
- **API** — success/error counts, average latency, rate-limit hits
- **Handlers** — pipeline outcomes (ok/error/exception/halted), ingress vs. duplicates
- **Rate Limiter** — allow/queue counts, drains, most recent block delay
- **Tier Limiter** — tokens remaining, per-method queueing, suspensions/resumes
- **Connection** — state transitions, rate-limited reconnects, health-check status

Enable `telemetry_stats` in config to get the full snapshot. Without it, the command falls back to lightweight counters from `TelemetryProbe`.

## Observing Rate Limiting

Attach a Telemetry handler in IEx to watch the rate limiter:

```elixir
:telemetry.attach(
  :rate_limiter_debug,
  [:slackbot, :rate_limiter, :decision],
  fn event, measurements, metadata, _ ->
    IO.inspect({event, measurements, metadata}, label: "rate_limiter")
  end,
  nil
)
```

See [Rate Limiting Guide](../../docs/rate_limiting.md) for details on how tier-aware limiting works.

## Diagnostics

Diagnostics are enabled by default (buffer size 200). Inspect or replay captured events:

```elixir
SlackBot.Diagnostics.list(BasicBot.SlackBot, limit: 5)
SlackBot.Diagnostics.replay(BasicBot.SlackBot, types: ["slash_commands"])
```

See [Diagnostics Guide](../../docs/diagnostics.md) for advanced workflows.

## Learn More

- [Getting Started](../../docs/getting_started.md) — create a Slack App from scratch
- [Slash Grammar](../../docs/slash_grammar.md) — full DSL reference
- [Rate Limiting](../../docs/rate_limiting.md) — how SlackBot paces API calls
- [Telemetry Dashboard](../../docs/telemetry_dashboard.md) — LiveDashboard integration
