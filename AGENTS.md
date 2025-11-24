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

## Adapters and extensibility

- Use the existing behaviours when introducing new backends:
  - Cache backends must implement `SlackBot.Cache.Adapter`.
  - Event buffer backends must implement `SlackBot.EventBuffer.Adapter`.

- Do not change the public behaviour contracts in application code. If a change to
  a behaviour is required, it must be coordinated with the library author.

## Telemetry, diagnostics and logging

- New Telemetry events should follow the existing naming pattern in `SlackBot.Telemetry`
  (prefix list plus concise event names).

- Diagnostics are **off by default** for safety. Only enable or expand diagnostics
  config in application code when explicitly requested.

- When adding logging:
  - Prefer using `SlackBot.Logging.with_envelope/3` where appropriate.
  - Avoid excessive or noisy logs at `:info` level; use `:debug` when possible.

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


