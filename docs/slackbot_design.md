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
  - handler DSL macros: `handle_event/3`, `handle_slash/3`, `handle_shortcut/3`, `middleware/1`
  - slash command ack strategy: `:silent` (default), `:ephemeral`, `{:custom, fun}`
  - cache adapter spec: `cache: {:ets, opts} | {:adapter, module, opts}`
  - event buffer adapter spec: `event_buffer: {:ets, opts} | {:adapter, module, opts}`
  - optional BlockBox toggle: `blocks: :none | {:blockbox, opts}`
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
- Legacy `handle_slash/3` handlers still work and now receive `payload["parsed"].args` from the tokenizer so existing bots avoid bespoke regex trees for mentions or structured snippets.

### Middleware & Diagnostics
- Middleware pipeline (plug-like): `before_event/3`, `after_event/4`.
- Diagnostics module offers per-connection ring buffer for incoming/outgoing frames, toggled via config for debugging.
- Logger metadata: `envelope_id`, `event_type`, `channel`, `user`, `request_id`.

## Developer Experience Enhancements
- **BlockBox integration (optional)**:
  - `use SlackBot.Blocks block_builder: :blockbox` injects helper functions; auto-detects dependency.
  - Graceful fallback to plain map builders when disabled.
  - Encourage best UX without forcing dependency.
- **Slash command auto-ack**: optional ephemeral “Processing…” message (default off). Configurable handler receives `response_url` for follow-ups.
- **Replay/simulation**: capture frames to disk/ETS, replay into handler pipeline for deterministic tests.
- **Testing helpers**: `SlackBot.TestTransport` to assert ack timing, handler execution, and telemetry emission without live Slack connection.
- **Telemetry docs**: sample `Telemetry.Metrics` definitions; instructions for wiring LiveDashboard (optional, Phoenix-only).

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

