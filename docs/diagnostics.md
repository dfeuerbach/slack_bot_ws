# Diagnostics & Replay Guide

SlackBot ships with first-class diagnostics so you can inspect and replay recent
Socket Mode activity without begging Slack to resend events. Enable diagnostics in
your runtime config and use the APIs below from `iex`, remote consoles, or tests.

> **Security note:** diagnostics entries preserve the full Slack payload, including user-
> generated content. Enable the buffer only when you can safely retain that data, and clear
> it once you’re done inspecting or replaying events.

## Enabling Diagnostics

```elixir
config :my_app, MyApp.SlackBot,
  app_token: "...",
  bot_token: "...",
  diagnostics: [enabled: true, buffer_size: 300]
```

- `enabled` — turn capture on/off (default: `false`).
- `buffer_size` — maximum number of frames kept per instance (default: `200`).

Diagnostics buffers live per SlackBot instance (derived from the supervisor name).

## Capturing Events Automatically

When enabled, SlackBot records:

- **Inbound frames** after dedupe: event type, payload, and envelope metadata.
- **Synthetic events** triggered via `SlackBot.emit/2`.
- **Outgoing frames** emitted through the socket transport (handy for debugging ack flows).

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

Combine them with the structured logging helpers
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

---

## Next Steps

- [Getting Started](getting_started.md) — set up a Slack App and run your first handler
- [Rate Limiting](rate_limiting.md) — understand how SlackBot paces Web API calls
- [Slash Grammar](slash_grammar.md) — build deterministic command parsers
- [Telemetry Dashboard](telemetry_dashboard.md) — correlate diagnostics with metrics

---

# Event Buffer Semantics (ETS & Redis)

SlackBot ships with an event buffer to dedupe Socket Mode envelopes (by `envelope_id`) and keep pending payloads visible for replay/inspection. Both built-in adapters (ETS and Redis) follow the same contract:

- **Idempotency**: `record/3` returns `:ok` once per key within the TTL window; subsequent calls return `:duplicate`.
- **First-write-wins payload + TTL refresh**: the first successful `record/3` defines the stored payload; duplicates do *not* overwrite it, but they refresh the TTL/dedupe window.
- **TTL correctness everywhere**: after expiry, `seen?/2` returns `false` and expired entries never appear in `pending/1`.
- **Pending order is deterministic**: `pending/1` returns payloads ordered by oldest “touch” first (touch = record or duplicate that refreshed TTL). Duplicates can move a key later in the list (by refreshing touch time) but never change its payload.
- **Namespace/instance isolation**: different `instance_name` (and Redis `namespace`) stay isolated.
- **Concurrency**: concurrent `record/3` calls yield exactly one `:ok`, the rest `:duplicate`.

### Choosing an adapter
- **ETS**: best for single-node use; zero external deps.
- **Redis**: best for multi-node dedupe; requires a shared Redis and unique `namespace`.

### Redis notes
- Keys live under `"<namespace>:<instance_name>:<key>"` and a pending ZSET at `"...:pending"`.
- TTL is managed by Redis; pending order uses a ZSET score based on the last touch time.
- Multi-node: two `EventBuffer.Server` processes sharing the same `namespace` and `instance_name` will dedupe against each other (see the Redis multi-node test for an example setup).

### Test helper (local + CI)
- The test suite auto-starts `redis:7-alpine` via Docker if `REDIS_URL` is unset; set `REDIS_URL` to use your own Redis. CI uses the same URL and a service container.
