# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

N/A

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
- Optional BlockBox integration for Block Kit helpers, `SlackBot.emit/2` for synthetic events.
- Example bot showcasing middleware, diagnostics, and slash grammars to accelerate ramp-up.
- Live diagnostics ring buffer with replay tooling so developers can reproduce issues locally without relying on Slack retries.

### Extensibility
- Pluggable event buffer and ack transports, configurable cache adapters, and `SlackBot.push/2` helper around `Req`.
- Hex package metadata plus changelog to support publishing to Hex.pm.

### What's Next?

After gathering community feedback and real-world validation:
- **0.1.0** - Stable release incorporating any RC feedback
- **1.0.0** - Long-term stable API with full semver guarantees

The path from RC to 1.0 will focus on validating the API in production rather than adding features. Breaking changes between RC and 1.0 will only be introduced if critical issues are discovered.

