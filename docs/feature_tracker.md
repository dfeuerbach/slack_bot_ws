# Feature Tracker

Progress tracker mapping `docs/slackbot_design.md` into sequential, commit-sized phases.

---

## Phase 1 – Runtime Config & Supervision Skeleton
**Status:** Completed  
Establish the foundational OTP structure so the application boots with validated configuration, even if downstream modules are stubs.

### Tasks
- [x] Define `%SlackBot.Config{}` struct with validation + env merging helpers.
- [x] Implement `SlackBot.ConfigServer` to serve immutable runtime config.
- [x] Scaffold `SlackBot.Supervisor` tree (ConfigServer plus placeholder children for downstream modules).
- [x] Add `SlackBot.Application` wiring (`start/2`) that boots the supervisor.
- [x] Provide initial doctests/unit tests for config validation edge cases.

### Testing
- `mix test test/slack_bot/config_test.exs`
- Add doctests in `SlackBot.Config`.

---

## Phase 2 – Connection, API Helpers & Ack Pipeline
**Status:** Completed  
Deliver the WebSockex-based connection manager with retry/backoff, heartbeat monitoring, fast acknowledgements, and the base public helpers (`SlackBot.push/2`, `SlackBot.emit/2`, test transport). Introduce stubbed cache/event-buffer modules so later phases can extend functionality without reordering work.

### Tasks
- [x] Implement `SlackBot.ConnectionManager` using WebSockex + `apps.connections.open`.
- [x] Port exponential backoff with rate-limit handling + configurable jitter.
- [x] Add heartbeat monitoring + reconnect triggers.
- [x] Wire runtime Task Supervisor for handler fan-out.
- [x] Introduce stubbed `SlackBot.EventBuffer` and `SlackBot.Cache` modules returning noop data until Phase 3 replaces them.
- [x] Expose `SlackBot.push/2`, `SlackBot.emit/2`, and runtime config helpers.
- [x] Provide `SlackBot.TestTransport` + `SlackBot.TestHTTP` for deterministic tests.
- [x] Unit/integration tests covering connection manager and SlackBot helpers.

### Testing
- `mix test test/slack_bot/connection_manager_test.exs`
- `mix test test/slack_bot_test.exs`
- Simulated socket-mode integration tests via `SlackBot.TestTransport`.

---

## Phase 3 – Event Buffer & Cache Providers
**Status:** Completed  
Replace the Phase 2 stubs with working dedupe/replay guarantees and provider/mutation queue caching with ETS defaults and adapter behaviours.

### Tasks
- [x] Define `SlackBot.EventBuffer` behaviour + ETS-backed adapter and wire it into the connection pipeline.
- [x] Support adapter configuration via config (`{:ets, opts}` or `{:adapter, mod, opts}`).
- [x] Implement Provider GenServer + Mutation Queue modules for channel/user caches.
- [x] Connect join/part/user events to cache mutations and expose read APIs.
- [x] Add regression tests for dedupe + cache mutation ordering.

### Testing
- `mix test test/slack_bot/event_buffer_test.exs`
- `mix test test/slack_bot/cache_test.exs`
- `mix test test/slack_bot/connection_manager_test.exs`

---

## Phase 4 – Command Router & Handler DSL
**Status:** Completed  
Ship the NimbleParsec-powered command/message parsing plus declarative handler DSL and middleware hooks, building on the stable connection/cache layers from earlier phases.

### Tasks
- [x] Implement NimbleParsec combinators for slash commands.
- [x] Provide `handle_event`, `handle_slash`, `middleware` macros.
- [x] Build middleware pipeline execution (before/after hooks).
- [x] Integrate parser output into handler invocation path with slash payload enrichment.
- [x] Add `slash/2` grammar DSL (literal/value/optional/repeat/choice) compiled to per-command parsers.
- [x] Unit tests for parsers, DSL-generated functions, and middleware behavior.

### Testing
- `mix test test/slack_bot/router_test.exs`
- `mix test test/slack_bot_test.exs`

---

## Phase 5 – Diagnostics, Telemetry & DX Enhancements
**Status:** Not Started  
Layer on optional BlockBox integration, slash-command auto-ack helpers, diagnostics/replay tooling, and documentation for telemetry consumers.

### Tasks
- [ ] Implement diagnostics ring buffer + replay tooling.
- [ ] Add structured logging metadata injection utilities.
- [ ] Integrate optional BlockBox helpers (compile-time detection, graceful fallback).
- [ ] Provide slash-command auto-ack strategies (`:silent`, `:ephemeral`, `{:custom, fun}`).
- [ ] Document Telemetry events + sample metrics definitions.
- [ ] Tests covering diagnostics toggles, BlockBox opt-in/out, auto-ack flows.
- [ ] Document every new public module/function with HexDocs-ready `@moduledoc`/`@doc`.

### Testing
- `mix test test/slack_bot/diagnostics_test.exs`
- When BlockBox enabled, run tagged tests that verify helper output (skip when dependency missing).

---

## Phase 6 – Docs, Examples & Final QA
**Status:** Not Started  
Polish user-facing documentation, sample bots, and perform end-to-end verification.

### Tasks
- [ ] Update `docs/slackbot_design.md` with implementation notes + deltas.
- [ ] Author README usage guide + quick-start sample (including BlockBox + parser examples).
- [ ] Provide LiveDashboard/Telemetry integration guide.
- [ ] Build sample bot in `examples/` demonstrating multi-phase features.
- [ ] Run full test suite, dialyzer (if configured), credo/format, and document results.
- [ ] Audit documentation coverage before publishing HexDocs (README, guides, `@doc`s).

### Testing
- `mix test`
- `mix format --check-formatted`
- `mix credo` / Dialyzer (if enabled)
- Manual smoke test against Slack socket-mode dev workspace.

