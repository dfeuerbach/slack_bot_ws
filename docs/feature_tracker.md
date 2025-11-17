# Feature Tracker

Progress tracker mapping `docs/slackbot_design.md` into sequential, commit-sized phases.

---

## Phase 1 – Runtime Config & Supervision Skeleton
**Status:** Not Started  
Establish the foundational OTP structure so the application boots with validated configuration, even if downstream modules are stubs.

### Tasks
- [ ] Define `%SlackBot.Config{}` struct with validation + env merging helpers.
- [ ] Implement `SlackBot.ConfigServer` to serve immutable runtime config.
- [ ] Scaffold `SlackBot.Supervisor` tree (ConfigServer, placeholder children).
- [ ] Add `SlackBot.Application` wiring (`start/2`) that boots the supervisor.
- [ ] Provide initial doctests/unit tests for config validation edge cases.

### Testing
- `mix test test/slack_bot/config_test.exs`
- Add doctests in `SlackBot.Config`.

---

## Phase 2 – Connection & Ack Pipeline
**Status:** Not Started  
Deliver the WebSockex-based connection manager with retry/backoff, heartbeat monitoring, and lightning-fast ack discipline plus baseline telemetry/logging.

### Tasks
- [ ] Implement `SlackBot.ConnectionManager` using WebSockex + `apps.connections.open`.
- [ ] Port exponential backoff with rate-limit handling + configurable jitter.
- [ ] Add heartbeat (15s ping/pong) monitor + reconnect triggers.
- [ ] Wire `SlackBot.TaskSupervisor` + PartitionSupervisor for handler fan-out.
- [ ] Emit telemetry/log metadata for connect/disconnect/ack timings.
- [ ] Unit + integration tests using a mocked WebSocket server (e.g., Mint/WebSockex test helper).

### Testing
- `mix test test/slack_bot/connection_manager_test.exs`
- Simulated socket-mode integration test harness asserting ack timing.

---

## Phase 3 – Event Buffer & Cache Providers
**Status:** Not Started  
Introduce dedupe/replay guarantees and provider/mutation queue caching with ETS defaults and adapter behaviours.

### Tasks
- [ ] Define `SlackBot.EventBuffer` behaviour + ETS-backed adapter (single-node default).
- [ ] Support pluggable adapters (Redis, etc.) via behaviour callbacks.
- [ ] Implement Provider GenServer + Mutation Queue modules for channel/user caches.
- [ ] Connect join/part events to cache mutations.
- [ ] Add classification tests covering dedupe, replay, and mutation ordering.

### Testing
- `mix test test/slack_bot/event_buffer_test.exs`
- Property tests (e.g., `StreamData`) for dedupe semantics.
- Optional Redis adapter tests guarded behind tag (requires docker/service).

---

## Phase 4 – Command Router & Handler DSL
**Status:** Not Started  
Ship the NimbleParsec-powered command/message parsing plus declarative handler DSL and middleware hooks.

### Tasks
- [ ] Implement NimbleParsec combinators for slash commands + mention triggers.
- [ ] Provide `handle_event`, `handle_slash`, `handle_shortcut`, `middleware` macros.
- [ ] Build middleware pipeline execution (before/after hooks).
- [ ] Integrate parser output into handler invocation path.
- [ ] Unit tests for parsers, DSL-generated functions, and middleware order guarantees.

### Testing
- `mix test test/slack_bot/command_router_test.exs`
- Parser doctests showcasing sample slash commands.

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

### Testing
- `mix test`
- `mix format --check-formatted`
- `mix credo` / Dialyzer (if enabled)
- Manual smoke test against Slack socket-mode dev workspace.

