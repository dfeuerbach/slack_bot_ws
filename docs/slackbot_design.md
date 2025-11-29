# SlackBot Design & Goals

## Goals
- **Performance & Survivability** – Maintain Slack’s 15 s ping/pong discipline via WebSockex, acknowledge envelopes immediately, and restart transports with exponential backoff + jitter. Handler work is faned out through `Task.Supervisor` so slow commands never block the socket loop.
- **Caching & State** – Provide bot-friendly snapshots of channels/users via the provider/mutation-queue pattern. The event buffer deduplicates envelopes and plugs into alternative backends (ETS by default, Redis or others via adapters) for multi-node deployments.
- **Developer Experience** – Expose a declarative handler DSL (events + slash commands) powered by NimbleParsec so teams define deterministic grammars without writing parsers. Optional BlockBox helpers keep Block Kit payloads ergonomic while remaining opt-in.
- **Observability & Telemetry** – Emit Telemetry events for connection lifecycle, handler spans, diagnostics record/replay, and rate limiting so Phoenix LiveDashboard (or any Telemetry consumer) can plot health metrics. Structured logging attaches envelope/channel metadata automatically.
- **Diagnostics & Testing** – Ship a built-in diagnostics ring buffer with list/clear/replay APIs, plus a test transport and mock HTTP client so developers can write focused unit tests. Replay makes production issues reproducible locally.
- **Extensibility & Deployment** – Treat configuration as data (`SlackBot.Config`), enabling pluggable cache/event-buffer adapters and multiple supervised instances inside the same BEAM node. All public modules carry `@doc` coverage for HexDocs.

## Public API & Configuration
- `SlackBot.start_link/1`: accepts keyword list or `%SlackBot.Config{}` with:
  - tokens/ids (`app_token`, `bot_token`, `team_id`, `user_id`, `bot_id`)
  - connection opts: `backoff: {min_ms, max_ms, max_attempts}`, `log_level`, `telemetry_prefix`
  - handler DSL macros: `handle_event/3`, `slash/2`, `middleware/1`
  - slash command ack strategy: `:silent` (default), `:ephemeral`, `{:custom, fun}` with per-command override
  - Web API pooling: `api_pool_opts` (forwarded to Finch; defaults to `name: <instance>.APIFinch`)
  - cache adapter spec: `cache: {:ets, opts} | {:adapter, module, opts}`
  - event buffer adapter spec: `event_buffer: {:ets, opts} | {:adapter, module, opts}`
  - diagnostics toggle: `diagnostics: [enabled: boolean(), buffer_size: pos_integer()]`
  - HTTP health monitor toggle: `health_check: [enabled: boolean(), interval_ms: pos_integer()]`
  - optional BlockBox toggle: `block_builder: :none | {:blockbox, opts}`
- Runtime helpers:
  - `SlackBot.push(bot, request)` – convenience wrappers around Slack Web API (backed by Req/Finch).
  - `SlackBot.emit(bot, event)` – inject synthetic events (testing/scheduled jobs).
  - `SlackBot.test_transport/1` – instrumentation-friendly fake transport for unit tests.

> Configuration is immutable after boot. Update the application environment and
> restart the `SlackBot` supervisor (or your enclosing app) to apply changes.

## Internal Architecture
```
SlackBot.Supervisor
├─ SlackBot.ConfigServer          # merges env, validates tokens, exposes runtime config
├─ SlackBot.ConnectionManager     # WebSockex client, backs off via apps.connections.open
├─ SlackBot.TaskSupervisor        # PartitionSupervisor + Task.Supervisor per connection
├─ SlackBot.EventBuffer           # behaviour; ETS default + custom adapters (Redis, etc.)
├─ SlackBot.TierLimiter           # Slack tier-aware request pacing per workspace/channel
├─ SlackBot.Cache.Provider        # read-through provider (channels, users, ims)
├─ SlackBot.Cache.Mutations       # mutation queue to satisfy Ratatouille conventions
├─ SlackBot.CommandRouter         # NimbleParsec-powered slash/message parsing + dispatch
├─ SlackBot.Telemetry             # instrumentation helpers + metric definitions
└─ SlackBot.Diagnostics           # structured logging, replay buffer, debug toggles
```

### Connection Manager
- Mirrors `Slack.Socket` backoff logic; parametrized jitter and max attempts.
- Relies on Slack’s Socket Mode lifecycle (`hello`, `disconnect` frames) and WebSocket errors for reconnect decisions instead of custom heartbeats.
- Immediately decodes envelopes, delegates to `SlackBot.EventBuffer` for dedupe bookkeeping, then spawns handler task and acks right away.
- Web API helpers reuse a per-instance Finch pool (`api_pool_opts`) so Req requests keep warm connections without starving slash-ack traffic (which uses a separate pool).

### Health Monitor
- `SlackBot.HealthMonitor` runs per instance and issues periodic `auth.test` requests through the configured HTTP client.
- Failed pings emit `[:slackbot, :healthcheck, :ping]` Telemetry and, for network errors, notify the connection manager to reset the transport using the existing backoff logic.
- Rate limits and fatal auth errors are surfaced via Telemetry but do not cause aggressive reconnect loops on their own.

### Tier & Rate Limiting
- `SlackBot.TierLimiter` enforces Slack’s published per-method quotas (Tier 1–4, special tiers)
  **before** requests reach the traditional `SlackBot.RateLimiter`. Each instance keeps per-workspace
  token buckets with configurable burst capacity and initial fill ratios so long-running jobs
  (for example the metadata sync) naturally pace themselves to shared budgets—`users.list` and
  `users.conversations` live in the same `:metadata_catalog` group—without relying on Slack’s
  429 responses or spiking during cold starts.
- The existing `SlackBot.RateLimiter` still handles per-channel serialization and honours Slack’s
  `Retry-After` guidance; combining both layers means requests trickle out steadily while respecting
  any temporary backoffs returned by Slack.

### Event Buffer & Caching
- `SlackBot.EventBuffer` behaviour with ETS-backed default (single-node). Adapter callbacks now center on `record(key, payload) :: {:ok | :duplicate, state}`, `delete/2`, `seen?/2`, and `pending/1`, letting the connection manager dedupe envelopes in a single RPC.
- Redis adapter ships with the toolkit (powered by `Redix`) so envelope dedupe/replay can be shared across nodes without additional plumbing.
- `SlackBot.Cache` exposes an adapter behaviour with `channels/2`, `users/2`, `metadata/2`, and `mutate/3`; the default ETS provider/mutation queue remains available, but you can plug Redis or any datastore while benefiting from the same public API. Set `mode: :async` inside the adapter opts when you want cache writes to be fire-and-forget.
- User entries are read-through with a one-hour TTL by default (`SlackBot.find_user/2` and the bot-specific helpers refresh stale or missing records transparently) and a supervised janitor removes expired rows on a configurable cadence. The full `users.list` background sync is now optional; channel membership sync remains enabled by default.

### Command Router & Parsing
- NimbleParsec baked in (non-optional). Default combinators handle:
  - positional slash-command arguments (plain or quoted segments)
  - lightweight key/value segments users often express inline (`env=prod`, `duration=5m`)
  - user/channel mentions (`<@U123>`, `<#C456>`) and emoji shortcuts
  - mention-triggered chat patterns (`@bot deploy foo`) without imposing CLI semantics.
- Grammar-aware DSL compiles declarative literals/values/optionals/repeats/choices into per-command parsers so handlers receive structured maps (`%{command: "cmd", short?: true, params: [...]}`) instead of raw token lists. See `docs/slash_grammar.md` for the full macro reference and examples.
- DSL example:
  ```elixir
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
  ```

### Middleware, Logging & Diagnostics
- Middleware pipeline (Plug-like) wraps every dispatch; middlewares can mutate payload/context or halt the chain entirely (`{:halt, resp}`), and **every** `handle_event/3` defined for a given type runs in declaration order so you can layer cache updates, metrics, and business logic without tangling responsibilities.
- Middleware entries are either modules implementing `call/3` or `{module, function}` tuples—anonymous middleware is intentionally disallowed so the pipeline remains introspectable.
- `SlackBot.Logging` attaches consistent metadata (`envelope_id`, `event_type`, `channel`, `user`) around handler execution.
- `SlackBot.Telemetry` centralizes event naming so connection lifecycle, handler timings, diagnostics actions, etc. emit consistent metrics (ready for LiveDashboard or custom collectors).
- `SlackBot.Diagnostics` provides per-instance ring buffer backed by ETS, capturing inbound/outbound frames with list/clear/replay APIs.

## Developer Experience Enhancements
- **BlockBox integration (optional)**:
  - Configure `%SlackBot.Config{block_builder: {:blockbox, opts}}` and call `SlackBot.Blocks.build/2` to run BlockBox’s DSL when the dependency is present.
  - Graceful fallback to map helpers (`SlackBot.Blocks.section/2`, `button/2`, etc.) when BlockBox isn’t installed.
- **Slash command auto-ack**: global/per-command `:silent | :ephemeral | {:custom, fun}` strategies. `:silent` is the default so no placeholder is sent unless you opt in; the `:ephemeral` option automatically posts “Processing…” via the slash `response_url`.
- **Replay/simulation**: diagnostics ring buffer + `SlackBot.Diagnostics.replay/2` feed captured events back through the router for deterministic debugging.
- **Telemetry & LiveDashboard**: `docs/telemetry_dashboard.md` explains how to hook the emitted events to LiveDashboard metrics or plain Telemetry handlers so teams can chart connection health without Phoenix dependencies baked into SlackBot.
- **Examples**: `examples/basic_bot` demonstrates slash DSL grammars, middleware, diagnostics replay, and auto-ack in a runnable Mix project.
- **Testing helpers**: `SlackBot.TestTransport` and `SlackBot.TestHTTP` ship in `lib/slack_bot/testing/`, so downstream projects can simulate Socket Mode or stub Slack Web API calls without copying fixtures.

## Feature Parity Checklist
- [x] WebSockex socket-mode client with `apps.connections.open` retries.
- [x] Immediate ack before heavy processing.
- [x] Task.Supervisor fan-out with PartitionSupervisor isolation.
- [x] Self-event filtering for user_id/bot_id.
- [x] Channel membership cache updates on join/part.
- [x] Rate-limit aware backoff and generic error retries.
- [x] Slash command payload handling (improved with parser + ack options).
- [x] Telemetry/logging instrumentation (new).
- [x] Event buffer + replay (new) while keeping dedupe guarantee.
- [x] Multi-node readiness via pluggable adapters.

## Next Steps
1. Flesh out `SlackBot.Config` struct validations and config-loading rules.
2. Scaffold supervisors and behaviours (cache, event buffer).
3. Implement NimbleParsec parsers and command DSL.
4. Integrate optional BlockBox layer with compile-time detection.
5. Provide documentation + examples demonstrating single-node ETS setup and Redis adapter wiring for clusters.

