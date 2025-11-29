# BasicBot Example

This sample Mix project shows how to wire SlackBot into an OTP application with:

- middleware + event handlers,
- the slash command grammar DSL with optional/repeat segments,
- diagnostics capture/replay,
- auto-ack strategies (`:ephemeral` + `{:custom, fun}`),
- optional BlockBox helpers (falls back to map builders if not installed),
- explicit ephemeral messaging and async Web API usage,
- robust connection health monitoring and automatic reconnects via the library’s HTTP-based health checks,
- per-channel Web API rate limiting using the library’s default rate limiter,
- a cache-backed `telemetry_stats` aggregator so `/demo telemetry` can surface handler outcomes, limiter queue lengths, tier suspensions/resumes, cache sync status, and health information without wiring extra Telemetry handlers.

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

Per-channel/per-workspace Web API rate limiting is **enabled by default** via the
library’s ETS-backed rate limiter—no extra configuration is required in this
example. Outbound calls made via `SlackBot.push/2` and `SlackBot.push_async/2`
are serialized per channel for common chat methods (`chat.postMessage`,
`chat.update`, `chat.delete`, `chat.scheduleMessage`, `chat.postEphemeral`),
with a workspace-level key for other methods. Slack `429` responses and
`Retry-After` headers drive the blocking window.

To observe rate limiting in action from `iex -S mix`, you can attach a simple
Telemetry handler:

```elixir
handler_id = {:basic_bot_rate_limiter, make_ref()}

:telemetry.attach(
  handler_id,
  [:slackbot, :rate_limiter, :decision],
  fn event, measurements, metadata, _ ->
    IO.inspect({event, measurements, metadata}, label: "rate_limiter")
  end,
  nil
)
```

## Slash Commands to Try

- `/demo list short fleet tag alpha tag beta`
- `/demo report platform`
- `/demo blocks`
- `/demo ping-ephemeral`
- `/demo async-demo`
- `/demo users`
- `/demo channels`
- `/demo telemetry`

### Telemetry snapshot

The example enables `telemetry_stats` in `config/config.exs`, so the `/demo telemetry` command renders a Block Kit card backed by `SlackBot.TelemetryStats.snapshot/1`. The card now explains:

- cache coverage (user/channel counts) and the most recent cache sync (kind, status, records processed, and duration),
- API throughput (success/error counts, average latency, rate-limit hits, latest method) plus handler pipeline outcomes (ok/error/exception/halted, ingress vs. duplicates, middleware halts, slash ack status),
- runtime rate limiter activity (allow/queue counts, drains, most recent block delay) and tier limiter state (tokens remaining, per-method queueing, suspensions/resumes with scope/delay details),
- connection states, rate-limited reconnects, and the latest health-check status.

If you disable `telemetry_stats`, the command falls back to the lightweight `TelemetryProbe` counters, but you won’t get the richer handler/limiter insights—keep the aggregator on for the full experience. The snapshot uses whatever cache adapter your bot is configured with (ETS in this example), so it works the same if you swap the cache for Redis.

When the bot is in a channel:

- Mention it with `@basic-bot` (or your app's bot handle) to get a quick help message.
- Run `/demo blocks` to see a Block Kit message; if BlockBox is installed and configured, it
  will use BlockBox to build the blocks, otherwise it falls back to map helpers.
- Run `/demo ping-ephemeral` to see an ephemeral message that only you can see.
- Run `/demo async-demo` to see a short series of async messages followed by a final summary.

The bot also replies to `@mention` events with instructions.

> If `BlockBox` is not in this example app's deps, you'll see a single warning about falling back
> to map helpers when you run `/demo blocks`. This is expected and safe.

## Diagnostics

Diagnostics are enabled by default (buffer size 200). From `iex -S mix` you can inspect
recent frames or replay them:

```elixir
SlackBot.Diagnostics.list(BasicBot.SlackBot, limit: 5)
SlackBot.Diagnostics.replay(BasicBot.SlackBot)
```

See the top-level `docs/diagnostics.md` for more advanced workflows.

