# SlackBot Agent Guide

This document is intended for coding agents (and other automation) that work with
applications using the `slack_bot_ws` library. It captures the core conventions and
non-obvious rules so that automated changes remain idiomatic and safe.

## Configuration and boot

- Always prefer the **`otp_app` pattern**:
  - Bot entrypoint modules should be defined as:

    ```elixir
    defmodule MyApp.SlackBot do
      use SlackBot, otp_app: :my_app
    end
    ```

  - Configuration belongs under the host application:

    ```elixir
    config :my_app, MyApp.SlackBot,
      app_token: System.fetch_env!("SLACK_APP_TOKEN"),
      bot_token: System.fetch_env!("SLACK_BOT_TOKEN")
    ```

  - Supervision should reference the bot module directly:

    ```elixir
    children = [
      MyApp.SlackBot
    ]
    ```

- Do **not** introduce new call sites using the older `{SlackBot, opts}` child spec form
  unless the project is already using it and the human author explicitly prefers it.

## Router and handlers

- Treat modules that `use SlackBot` **without** `otp_app:` as **routers**, not processes.
  They define:
  - `handle_event/3` macros for events.
  - `slash/2` + `grammar/1` for slash commands.
  - `middleware/1` for the middleware pipeline.

- Do not attempt to supervise router modules directly; always supervise the bot entrypoint
  module (the one that `use`s `SlackBot, otp_app: ...`).

- When adding handlers:
  - Prefer pattern matching and guards instead of deeply nested `case` or `if`.
  - Keep business logic in separate functions or modules rather than large handler bodies.

## Public API usage

- Use these helpers instead of reaching into internal modules:
  - `SlackBot.push(bot, {method, body})` for Web API calls.
  - `SlackBot.push_async(bot, {method, body})` for async Web API calls.
  - `SlackBot.emit(bot, {type, payload})` to inject synthetic events.
  - `SlackBot.config(bot)` to read immutable configuration.

- Avoid calling internal modules like `SlackBot.API`, `SlackBot.ConnectionManager`,
  `SlackBot.ConfigServer`, or adapter modules directly from application code unless
  the human maintainer explicitly requests it.

## Configuration options

- Assume that **omitting options is safe**:
  - Backoff, heartbeat, cache/event buffer, diagnostics, and ack strategy all have
    reasonable defaults when not set.
  - Only introduce configuration keys when they solve a real requirement.

- When adding or modifying configuration:
  - Keep all options for a bot under a single `config :my_app, MyBot.SlackBot, ...` block.
  - Prefer small, incremental changes rather than large, auto-generated blocks.
  - Respect the types and validation rules in `SlackBot.Config` (for example
    `ack_mode`, `diagnostics`, `cache`, `event_buffer`).

- **Quick reference** for the most common keys (see `SlackBot.Config` for full docs):
  - `backoff`: `%{min_ms: 1_000, max_ms: 30_000, max_attempts: :infinity, jitter_ratio: 0.2}`. Keep `min_ms < max_ms`, positive integers, and `0 <= jitter_ratio <= 1`.
  - `cache` / `event_buffer`: `{:ets, opts}` by default; switch to `{:adapter, Module, opts}` only when you already have a behaviour-compliant backend. Keep opts keyword lists.
  - `rate_limiter`: default `{:adapter, SlackBot.RateLimiter.Adapters.ETS, []}`. Use `:none` only when the human author explicitly accepts unshaped API traffic.
  - `cache_sync`: `%{enabled: true, interval_ms: 3_600_000, kinds: [:channels], users_conversations_opts: %{}}`. Accepts maps or keyword lists; `kinds` must be a non-empty subset of `[:users, :channels]`.
  - `user_cache`: `%{ttl_ms: 3_600_000, cleanup_interval_ms: 300_000}`. Keep both values positive.
  - `telemetry_stats`: `%{enabled: false, flush_interval_ms: 15_000, ttl_ms: 300_000}`. Set to `true` or a keyword/map to enable the telemetry snapshotter.
  - `diagnostics`: `%{enabled: false, buffer_size: 200}`. Accepts booleans, keyword lists, or maps. Keep buffer sizes positive and enable only when the maintainer approves retaining payloads.
  - `ack_mode`: `:silent | :ephemeral | {:custom, (map(), SlackBot.Config.t() -> any())}`. Custom functions must be arity 2 and never block.
  - `block_builder`: `:none` or `{:blockbox, opts}` when the project uses BlockBox helpers.
  - `api_pool_opts`: forwarded to Finch (`[pools: %{default: [size: 20, count: 2]}]` is a typical shape). Stay within Finch’s supported options.
  - `assigns`: map-only; set `:bot_user_id` when cache sync needs zero-cost membership checks, or `:slash_ack_text` when opting into `:ephemeral` acks.
  - `telemetry_prefix`: list of atoms (`[:slackbot]` default). Never mix types.
  - `instance_name`, `transport`, `transport_opts`, `http_client`, `ack_client`: module references only; no anonymous functions.

## Adapters and extensibility

- Use the existing behaviours when introducing new backends:
  - Cache backends must implement `SlackBot.Cache.Adapter`.
  - Event buffer backends must implement `SlackBot.EventBuffer.Adapter`.

- Do not change the public behaviour contracts in application code. If a change to
  a behaviour is required, it must be coordinated with the library author.

## Telemetry, diagnostics and logging

- Prefer `telemetry_prefix` overrides only when multiple bots coexist in the same BEAM node; keep prefixes short and list-only so `Telemetry.Metrics` signatures remain stable.
- Enable `telemetry_stats` when automation needs rolled-up counters (`SlackBot.TelemetryStats.snapshot/1`). The stats process attaches to your prefix automatically; no additional wiring is needed beyond the config block.
- Reference `docs/telemetry_dashboard.md` when adding LiveDashboard metrics or custom handlers. Reuse its `Telemetry.Metrics` definitions instead of inventing new ones.
- Diagnostics buffers (`diagnostics: [enabled: true, buffer_size: 300]`) retain full Slack payloads. Confirm with the maintainer that retaining user text is acceptable, and clear the buffer after use.
- New Telemetry events should follow the existing naming pattern in `SlackBot.Telemetry`
  (prefix list plus concise event names).

- Diagnostics are **off by default** for safety. Only enable or expand diagnostics
  config in application code when explicitly requested.

- When adding logging:
  - Prefer using `SlackBot.Logging.with_envelope/3` where appropriate.
  - Avoid excessive or noisy logs at `:info` level; use `:debug` when possible.

## Rate limiting and Web API shaping

- All outbound Web API calls should go through `SlackBot.push/2` or `SlackBot.push_async/2` so both the per-channel rate limiter and the tier limiter can see the traffic.
- `rate_limiter: :none` removes the per-channel queues—only use it when a maintainer explicitly confirms the workload is already shaped elsewhere.
- Tier-level quotas live in `SlackBot.TierRegistry`. Override entries via `config :slack_bot_ws, SlackBot.TierRegistry, tiers: %{}` when Slack changes quotas or custom grouping is needed. Keep `:max_calls`, `:window_ms`, and `:scope` consistent with README guidance.
- Pay attention to `[:slackbot, :rate_limiter, ...]` and `[:slackbot, :tier_limiter, ...]` telemetry events before changing limiter settings. Spikes in `queue_length` mean you should coordinate with the maintainer before dialing back safeguards.

## Metadata cache and sync

- Default cache + event buffer adapters use ETS. Stick with them unless the project already depends on a custom adapter that implements `SlackBot.Cache.Adapter` / `SlackBot.EventBuffer.Adapter`.
- Keep `cache_sync` enabled unless the maintainer asks to disable it. It keeps users/channels fresh via `users.conversations` and surfaces helpers like `SlackBot.Cache.channels/1`.
- When narrowing sync scope, prefer `cache_sync: [kinds: [:channels], users_conversations_opts: %{types: "..."}]` over ad-hoc Slack API calls inside handlers.
- Set `assigns: %{bot_user_id: "U123"}` once the bot user ID is known so the cache can track membership without extra API calls.
- Respect `user_cache` TTL/cleanup values; do not mutate `%SlackBot.Config{}` structs in place to force refreshes. Use the cache helpers or explicit Slack API calls routed through `SlackBot.push/2`.

## Slash command acknowledgements

- Default `ack_mode` is `:silent`, so commands only post their final response. Opt into `:ephemeral` in config or per-command assigns when the maintainer wants the “Processing…” placeholder.
- Custom ack callbacks must be idempotent and fast; they receive the parsed command map plus the immutable `%SlackBot.Config{}`. Never perform blocking I/O inside the callback—delegate to a Task if needed.
- `ack_client` defaults to `SlackBot.SlashAck.HTTP`. Override it only when tests provide a fake HTTP client or when the project introduces a custom transport.

## Testing helpers

- Prefer `SlackBot.TestTransport` and `SlackBot.TestHTTP` (under `lib/slack_bot/testing/`) for automated tests. They simulate Socket Mode frames and Web API responses without hitting Slack.
- When writing new tests, start from `examples/basic_bot/` for guidance on slash grammar, telemetry probes, and diagnostics replay. Reuse its helpers instead of creating bespoke test harnesses.

## Anti-patterns to avoid

- Do not:
  - Bypass the cache or event buffer when handling inbound events.
  - Modify internal state in `SlackBot.Config` structs in-place.
  - Introduce new global process names that do not follow the existing naming
    scheme (`<Instance>.ConfigServer`, `<Instance>.ConnectionManager`, etc.).

- When in doubt:
  - Prefer adding a small, well-documented helper function in the host application
    over extending SlackBot’s public API.
  - Ask the human maintainer to confirm any architectural changes.


