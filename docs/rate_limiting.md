# Rate Limiting

Slack imposes rate limits on Web API calls to protect its infrastructure and ensure fair access across all apps. If your bot exceeds these limits, Slack returns `429 Too Many Requests` with a `Retry-After` header indicating how long to wait.

SlackBot handles rate limiting automatically through two complementary layers:

1. **Rate limiter** – Shapes bursts on a per-channel (for the “chat.*” family) or per-workspace basis so you don’t overrun Slack’s immediate-rate guardrails. This is the component invoked before each Web API call via `MyBot.push/1` (or `SlackBot.push(bot, request)`) and `MyBot.push_async/1`.

2. **Tier limiter** – Tracks Slack’s published per-method quotas (Tier 1–4 + special tiers) and queues requests so you honor the longer-term limits documented in [Slack’s API rate guide](https://docs.slack.dev/apis/web-api/rate-limits).

## Rate limiter (“burst” protection)

Every outbound Web API call goes through the built-in rate limiter by default. It keeps a queue per “key” (per-channel for chat-style methods, per-workspace for others) and gates entry so you never run more than one request per key when Slack’s rules would reject you anyway (e.g., Slack’s 1 message/second/channel policy). If Slack responds with `429` and a `Retry-After`, the limiter suspends that key for the specified duration before draining the queue.

You can observe back pressure by subscribing to the built-in telemetry:

* `[:slackbot, :rate_limiter, :decision]` with `decision: :queue` and `measurement[:queue_length]` whenever a request has to wait.
* `[:slackbot, :rate_limiter, :blocked]` whenever a key is paused due to a `Retry-After`.

These events can be fed into `Telemetry.Metrics` (e.g., `last_value` or `distribution`) to derive average queue depths or to detect when Slack is throttling a key.

Because the rate limiter is enforcing Slack’s pacing rules, it does not have its own timeout; the `GenServer.call/3` inside `around_request/4` uses `:infinity` so requests will sit in the queue until Slack allows them to proceed. If you need a client-side timeout, wrap your `MyBot.push/1` call (or the explicit `SlackBot.push(bot, ...)`) in your own `Task.async/await` with a timeout and cancel the task if you can’t wait.

The limiter also guarantees that slots are released even if your code raises, throws, or exits. Each request is wrapped in a `try/rescue/catch` so the `{:after_request, ...}` bookkeeping message is delivered no matter how the user function finishes.

## Tier-based quotas

Slack groups Web API methods into “tiers” (1–4 plus a few special buckets) that define how many calls per minute you can make per workspace. SlackBot ships with a tier registry that encodes those quotas: each method maps to a spec with `max_calls`, `window_ms`, `scope`, optional `group` sharing, and (for “special” cases like `chat.postMessage`) a reasonable default based on Slack’s docs. The tier limiter tracks each spec independently and queues requests so you don’t exceed the published budget.

You typically don’t need to configure this at all. If Slack updates their quotas or if you have an alternative agreed-upon allotment, you can override entries via:

```elixir
config :slack_bot_ws, SlackBot.TierRegistry,
  tiers: %{
    "users.list" => %{max_calls: 10, window_ms: 45_000},
    "users.conversations" => %{group: :my_custom_group}
  }
```

Note that the tier registry is eager for correctness: it only encodes the methods documented by Slack today, and defaults to `:workspace` scope unless Slack mandates `{:channel, field}` or a shared group. Don’t set arbitrary `scope`/`max_calls` values unless you’re aligning with Slack’s guidance.

## Observability

All limiter activity is surfaced via `:telemetry` to make it easy to build dashboards and alerts. In addition to the rate limiter events above, the tier limiter emits:

* `[:slackbot, :tier_limiter, :decision]` with `queue_length` and remaining `tokens` whenever a method increments or queues.
* `[:slackbot, :tier_limiter, :suspend]` and `[:slackbot, :tier_limiter, :resume]` when a tier budget is paused due to Slack saying “slow down” and when it resumes.

You can register metrics on these events (e.g., average queue length, number of suspensions per key, token utilization) to understand how close you are to Slack’s limits.

## Configuration cheatsheet

* `rate_limiter: :none` – disables the per-key burst limiter if you absolutely must bypass client-side shaping (not recommended unless your infrastructure enforces Slack’s per-channel/per-workspace rates).
* `config :slack_bot_ws, SlackBot.TierRegistry, tiers: %{...}` – override or add per-method specs if you’ve negotiated bespoke quotas with Slack.
* `api_pool_opts` – still controls the HTTP client’s timeout/connection pool, independently of the limiter’s logic.

By default, leaving the limiters enabled is the safest way to stay on Slack’s good side: your bot will queue and pace its calls locally, honor Slack’s published quotas, and surface telemetry so you can react before hitting hard API caps.
