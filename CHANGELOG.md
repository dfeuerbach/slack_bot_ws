# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- _Nothing yet_

## [0.1.0-rc.2] - 2025-12-25

### Added
- `use SlackBot, otp_app: ...` now injects instance helper functions (`push/1`, `push_async/1`, `emit/1`, `config/0`) so downstream code can call `MyApp.SlackBot.push({...})` without repeating the module name at every callsite.
- Expanded `SlackBot.TierRegistry` defaults to cover Slack's published tier list (including special cases like `chat.postMessage`) along with regression tests.
- Redis-backed event buffer conformance harness that exercises every adapter scenario (ETS + Redis) plus multi-node Redis coverage.
- Live Redis test helper that auto-starts `redis:7-alpine` for `mix test` and mirrors the GitHub Actions Redis service setup.

### Changed
- README, guides, and the example bot now use the new instance helpers exclusively and document the recommended “one module per bot” pattern (plus guidance for the explicit multi-instance form).
- Refreshed the README landing narrative to more clearly explain SlackBot’s goals and quick-start path.
- Simplified the slash command DSL so grammar definitions live directly before `handle/3`, removing the `grammar do ... end` wrapper and updating docs, examples, and tests accordingly.
- Event buffer adapters now share strict semantics (first-write-wins payload, TTL refresh, deterministic `pending/1`, TTL-correct `seen?/2`) with normalized telemetry events.
- CI `test` matrix now provisions a Redis service and exports `REDIS_URL` so Redis-backed tests run in automation by default.
- README and docs now document live Redis testing expectations, event buffer semantics, and telemetry event shapes.

### Breaking
- Removed the implicit `SlackBot.*/*` arities that defaulted to the `SlackBot` module. Call `MyBot.push/1`, `MyBot.push_async/1`, `MyBot.emit/1`, or `MyBot.config/0` (the injected helpers), or keep using the explicit forms (`SlackBot.push(bot, request)`, etc.) when supervising bots under custom names.

### Fixed
- Suppressed optional Igniter and Rewrite module warnings in `mix slack_bot_ws.install` when those helper dependencies are not present.
- Avoid blocking the users cache sync worker during Slack rate limits by scheduling retries instead of sleeping.
- `EventBuffer.delete/2` now routes through a single synchronous code path, preventing stale state when deleting entries across adapters.

## [0.1.0-rc.1] - 2025-12-01

**Initial Release Candidate**

This release candidate represents what I expect will become the 1.0 stable API.

**Feedback Welcome!** If you encounter issues, have suggestions, or want to share your experience, please [open an issue on GitHub](https://github.com/dfeuerbach/slack_bot_ws/issues).

### What's Included

### Performance & Scalability
- Supervised WebSockex connection manager with immediate envelope ACKs and Task.Supervisor fan-out so handlers never block the socket loop.
- Event buffer dedupe with ETS-backed default and adapters, plus jittered exponential backoff to stagger reconnect attempts across nodes.
- Fast, deterministic slash command routing for predictable dispatch.
- Dedicated Finch pool for Slack Web API traffic (`api_pool_opts`) so Req calls reuse warm connections and can be tuned per bot.

### Robustness & Resiliency
- Runtime config server that validates config and fans out immutable `%SlackBot.Config{}` structs to every process.
- Provider/mutation-queue cache pattern for channels/users with automatic updates on join/leave/user-change events.
- Heartbeat monitoring, ping/pong responses, and rate-limit-aware reconnects that respect Slack’s expected disconnect/reconnect lifecycle.

### Observability
- Telemetry events for connection lifecycle, rate limiting, handler spans, diagnostics, Slack Web API calls (`SlackBot.push/2`), and slash ack HTTP posts.
- Diagnostics ring buffer with list/clear/replay APIs plus structured logging helpers for envelope metadata.
- HexDocs-ready references (README, diagnostics, telemetry dashboard guides) describing how to wire LiveDashboard metrics.

### Developer Experience
- Declarative handler DSL (`handle_event`, `slash`, grammar combinators, middleware) powered by NimbleParsec for deterministic slash command parsing.
- Slash auto-ack strategies (`:silent`, `:ephemeral`, `{:custom, fun}`) with configurable default text and response-url transport.
- Plug-like middleware pipeline for cross-cutting concerns (logging, auth, metrics) across all handlers, with sequential execution of every `handle_event/3` defined for an event type and short-circuit control via `{:halt, resp}`.
- Optional BlockBox integration for building rich Block Kit payloads with ergonomic Elixir DSL.
- `SlackBot.emit/2` for injecting synthetic events into the handler pipeline (testing, scheduled tasks, internal events).
- `mix slack_bot_ws.install` task powered by Igniter for zero-config scaffolding of bot module, config, and supervision wiring.
- Complete runnable example bot in `examples/basic_bot/` (included in GitHub repo) demonstrating middleware, diagnostics, slash grammars, Block Kit, cache queries, and telemetry.
- Live diagnostics ring buffer with replay tooling so developers can reproduce issues locally without relying on Slack retries.
- Comprehensive API documentation with real Slack response structures, complete error handling patterns, and common error codes documented.
- Copy-paste ready code examples throughout showing practical usage patterns for Web API calls, cache queries, and event handling.
- "When to use" decision guidance for function variants (push vs push_async, ID vs email matchers, adapter choices).
- Performance tips and caching behavior explanations for every public function.
- Complete test helper documentation (TestHTTP, TestTransport) with full test examples for unit testing handlers.

### Extensibility
- Pluggable cache adapters via `SlackBot.Cache.Adapter` behaviour (ETS default, Redis implementation included).
- Pluggable event buffer adapters via `SlackBot.EventBuffer.Adapter` behaviour for multi-node dedupe strategies.
- Configurable HTTP client and WebSocket transport for testing and custom integrations.
- Custom slash command acknowledgement callbacks for domain-specific response patterns.

### What's Next?

After gathering community feedback and real-world validation, and possible adjustments to documentation:
- **0.1.0** - Initial release incorporating any RC feedback. Intention to move to 1.0 as soon as possible.
- **1.0.0** - Long-term stable API with full semver guarantees

The path from RC to 1.0 will focus on validating the API in production rather than adding features. Breaking changes between RC and 1.0 will only be introduced if critical issues are discovered.

