# SlackBot Assessment & Redesign

## Reference: `Slack.Socket`
- Websocket lifecycle via `WebSockex`, `apps.connections.open` acquisition, and exponential backoff with rate-limit awareness.  
```
21:155:/Users/dougf/dev/p/slack_bot_ws/ref/slack_elixir/lib/slack/socket.ex
@impl WebSockex
def handle_frame({:text, msg}, state) do
  case Jason.decode(msg) do
    {:ok, %{"payload" => %{"event" => event}} = msg} ->
      Task.Supervisor.start_child(...)
      {:reply, ack_frame(msg), state}
  end
end
```
- Immediate ack before heavy work, partitioned task supervision, and guardrails for self-generated events.
- Channel cache mutations handled via `Slack.ChannelServer` when bot joins/leaves channels.
- Gaps: no top-level config surface, no telemetry/logging hooks beyond raw Logger calls, no slash-command ergonomics, minimal caching, no middleware/testing/replay facilities, single-node assumption, no heartbeat monitoring visibility.

## SlackBot Goals
1. Match all robustness characteristics (fast ack, retries, channel cache, supervised handlers, self-event filters, ping/reconnect discipline).
2. Provide a first-class `SlackBot` API with declarative configuration and handler DSL.
3. Offer delightful developer experience: slash-command/chat parsing via NimbleParsec (always-on), optional BlockBox block builders, middleware, replay/testing, structured logging, and telemetry hooks.
4. Support multi-node readiness via pluggable cache/event buffer adapters (ETS default, Redis/others via behaviour).

## Public API & Configuration
- `SlackBot.start_link/1`: accepts keyword list or `%SlackBot.Config{}` with:
  - tokens/ids (`app_token`, `bot_token`, `team_id`, `user_id`, `bot_id`)
  - connection opts: `backoff: {min_ms, max_ms, max_attempts}`, `heartbeat_ms`, `ping_timeout_ms`, `log_level`, `telemetry_prefix`
  - handler DSL macros: `handle_event/3`, `slash/2`, `middleware/1`
  - slash command ack strategy: `:silent` (default), `:ephemeral`, `{:custom, fun}` with per-command override
  - cache adapter spec: `cache: {:ets, opts} | {:adapter, module, opts}`
  - event buffer adapter spec: `event_buffer: {:ets, opts} | {:adapter, module, opts}`
  - diagnostics toggle: `diagnostics: [enabled: boolean(), buffer_size: pos_integer()]`
  - optional BlockBox toggle: `block_builder: :none | {:blockbox, opts}`
- Runtime helpers:
  - `SlackBot.push(bot, request)` – convenience wrappers around Slack Web API (backed by Req/Finch).
  - `SlackBot.emit(bot, event)` – inject synthetic events (testing/scheduled jobs).
  - `SlackBot.test_transport/1` – instrumentation-friendly fake transport for unit tests.

## Internal Architecture
```
SlackBot.Supervisor
├─ SlackBot.ConfigServer          # merges env, validates tokens, exposes runtime config
├─ SlackBot.ConnectionManager     # WebSockex client, backs off via apps.connections.open
├─ SlackBot.TaskSupervisor        # PartitionSupervisor + Task.Supervisor per connection
├─ SlackBot.EventBuffer           # behaviour; ETS default + custom adapters (Redis, etc.)
├─ SlackBot.Cache.Provider        # read-through provider (channels, users, ims)
├─ SlackBot.Cache.Mutations       # mutation queue to satisfy Ratatouille conventions
├─ SlackBot.CommandRouter         # NimbleParsec-powered slash/message parsing + dispatch
├─ SlackBot.Telemetry             # instrumentation helpers + metric definitions
└─ SlackBot.Diagnostics           # structured logging, replay buffer, debug toggles
```

### Connection Manager
- Mirrors `Slack.Socket` backoff logic; parametrized jitter and max attempts.
- Tracks Slack 15s ping/pong expectations; emits telemetry + triggers reconnect when heartbeats lapse.
- Immediately decodes envelopes, delegates to `SlackBot.EventBuffer` for dedupe bookkeeping, then spawns handler task and acks right away.

### Event Buffer & Caching
- `SlackBot.EventBuffer` behaviour with ETS-backed default (single-node). Adapter callbacks: `insert(envelope_id)`, `seen?(envelope_id)`, `delete(envelope_id)`, `fetch_pending/0`.
- Custom adapters (Redis, Database) can be plugged for multi-node dedupe/replay.
- `SlackBot.Cache` follows provider/mutation-queue pattern: reads via provider GenServer, writes funneled through mutation queue, supporting channel membership, user profile snapshots, and conversation metadata.

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
- Middleware pipeline (plug-like) wraps every dispatch; shared modules (logging, metrics, auth) can short-circuit or mutate payloads.
- `SlackBot.Logging` attaches consistent metadata (`envelope_id`, `event_type`, `channel`, `user`) around handler execution.
- `SlackBot.Telemetry` centralizes event naming so connection lifecycle, handler timings, diagnostics actions, etc. emit consistent metrics (ready for LiveDashboard or custom collectors).
- `SlackBot.Diagnostics` provides per-instance ring buffer backed by ETS, capturing inbound/outbound frames with list/clear/replay APIs.

## Developer Experience Enhancements
- **BlockBox integration (optional)**:
  - Configure `%SlackBot.Config{block_builder: {:blockbox, opts}}` and call `SlackBot.Blocks.build/2` to run BlockBox’s DSL when the dependency is present.
  - Graceful fallback to map helpers (`SlackBot.Blocks.section/2`, `button/2`, etc.) when BlockBox isn’t installed.
- **Slash command auto-ack**: global/per-command `:silent | :ephemeral | {:custom, fun}` strategies. The `:ephemeral` option automatically posts “Processing…” via the slash `response_url`.
- **Replay/simulation**: diagnostics ring buffer + `SlackBot.Diagnostics.replay/2` feed captured events back through the router for deterministic debugging.
- **Telemetry & LiveDashboard**: `docs/telemetry_dashboard.md` explains how to hook the emitted events to LiveDashboard metrics or plain Telemetry handlers so teams can chart connection health without Phoenix dependencies baked into SlackBot.
- **Examples**: `examples/basic_bot` demonstrates slash DSL grammars, middleware, diagnostics replay, and auto-ack in a runnable Mix project.
- **Testing helpers**: `SlackBot.TestTransport` to assert ack timing, handler execution, and telemetry emission without live Slack connection.

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

