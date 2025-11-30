# Rate Limiting

Slack imposes rate limits on Web API calls to protect its infrastructure and ensure fair access across all apps. If your bot exceeds these limits, Slack returns `429 Too Many Requests` with a `Retry-After` header indicating how long to wait.

SlackBot handles rate limiting automatically through two complementary layers. This guide explains what Slack enforces, how SlackBot responds, and when you might want to tune the defaults.

## Slack's Rate Limit Structure

Slack organizes rate limits into two dimensions:

### Per-Channel / Per-Workspace Limits

High-volume methods like `chat.postMessage` have per-channel burst limits. Sending many messages to the same channel in quick succession triggers throttling even if your overall API usage is moderate. Other methods use workspace-level limits.

### Tier-Based Quotas

Slack groups methods into tiers with different quotas:

| Tier | Typical Quota | Example Methods |
|------|---------------|-----------------|
| Tier 1 | 1 per minute | `chat.delete`, `files.delete` |
| Tier 2 | 20 per minute | `users.list`, `users.conversations`, `conversations.list` |
| Tier 3 | 50 per minute | `chat.postMessage`, `reactions.add` |
| Tier 4 | 100+ per minute | `users.info`, `conversations.info` |
| Special | Varies | Some methods have unique limits |

These quotas are per-workspace, not per-channel. A bot calling `users.list` 20 times in a minute will be rate-limited on the 21st call regardless of which channels it's active in.

> **On burst traffic:** Slack's quotas are rolling averages, so short bursts within a window may succeed. However, sustained bursts quickly exhaust the quota. SlackBot's tier limiter allows controlled bursting (25% headroom by default via `burst_ratio`) while smoothing sustained traffic to stay within limits—you get responsiveness for spikes without overly risking `429` responses on heavy workloads.

## How SlackBot Handles This

SlackBot uses two complementary limiters. Both run before any request reaches Slack.

### Tier Limiter (Method Quotas)

The tier limiter enforces Slack's published per-method quotas proactively. Each method belongs to a tier (or group of methods sharing a budget). SlackBot maintains a token bucket for each:

- Tokens refill over time according to the tier's quota
- A request consumes one token
- If no tokens are available, the request waits (queues) until tokens refill

This means your bot naturally paces itself to stay within Slack's published limits, rather than blasting requests and waiting for `429` responses.

### Per-Channel Rate Limiter (Burst & 429 Handling)

For chat methods (`chat.postMessage`, `chat.update`, `chat.delete`, `chat.scheduleMessage`, `chat.postEphemeral`), requests are keyed by channel ID to prevent flooding a single channel. Other methods use a workspace-level key.

If Slack returns `429`, the rate limiter:

1. Reads the `Retry-After` header
2. Blocks subsequent requests to that key until the window expires
3. Drains queued requests once the window passes

This layer handles the cases where Slack imposes limits beyond the published tiers—channel-specific throttling or unexpected rate-limit responses.

### What This Means for You

In most cases, you don't need to think about rate limiting at all:

```elixir
# This just works—SlackBot paces these calls automatically
for channel_id <- channels do
  SlackBot.push(bot, {"chat.postMessage", %{
    "channel" => channel_id,
    "text" => "Hello!"
  }})
end
```

If you're calling many different methods in a tight loop, the tier limiter queues requests so they trickle out at the correct rate:

```elixir
# users.list and users.conversations share the Tier 2 budget (20/min)
# SlackBot queues automatically so you don't hit 429
SlackBot.push(bot, {"users.list", %{}})
SlackBot.push(bot, {"users.conversations", %{}})
```

## Telemetry Events

Both limiters emit Telemetry events so you can observe their behavior:

| Event | What It Means |
|-------|---------------|
| `[:slackbot, :rate_limiter, :decision]` | A request was allowed or queued; includes `queue_length` and `in_flight` counts |
| `[:slackbot, :rate_limiter, :blocked]` | Slack returned `429`; includes `delay_ms` |
| `[:slackbot, :rate_limiter, :drain]` | Queued requests were released after a block window |
| `[:slackbot, :tier_limiter, :decision]` | A method was allowed or queued; includes `tokens` remaining |
| `[:slackbot, :tier_limiter, :suspend]` | A tier bucket was suspended due to `429`; includes `delay_ms` |
| `[:slackbot, :tier_limiter, :resume]` | A suspended bucket resumed |

If you're seeing `queue_length` spikes, your bot may be generating requests faster than Slack allows. Consider batching work or spreading it over time.

## Configuration

### Disabling Rate Limiting

If you have external shaping (a proxy, another rate limiter), you can disable SlackBot's:

```elixir
config :my_app, MyApp.SlackBot,
  rate_limiter: :none
```

This is rarely needed. The default ETS-backed limiter has minimal overhead.

### Customizing the Rate Limiter Adapter

```elixir
config :my_app, MyApp.SlackBot,
  rate_limiter: {:adapter, SlackBot.RateLimiter.Adapters.ETS, [
    table: :my_custom_table,
    ttl_ms: 10 * 60_000
  ]}
```

### Overriding Tier Registry Entries

If Slack changes quotas or you need custom grouping:

```elixir
config :slack_bot_ws, SlackBot.TierRegistry,
  tiers: %{
    # Lower the quota for users.list
    "users.list" => %{max_calls: 10, window_ms: 60_000},

    # Group a custom method with metadata calls
    "my.custom.method" => %{group: :metadata_catalog}
  }
```

Each entry supports:

| Key | Description |
|-----|-------------|
| `:max_calls` | Maximum calls per window |
| `:window_ms` | Window duration in milliseconds |
| `:scope` | `:workspace` or `{:channel, field}` |
| `:group` | Atom to share a budget with other methods |
| `:burst_ratio` | Additional burst headroom (default 0.25) |
| `:initial_fill_ratio` | How full new buckets start (default 0.5) |
| `:tier` | Informational label |

## Background Sync Considerations

SlackBot's cache sync calls `users.conversations` to keep channel membership current. This method is Tier 2 (20/min). If you have many channels or enable user sync, the sync spreads calls over time automatically.

If you see `[:slackbot, :tier_limiter, :suspend]` events during sync, the sync is working correctly—it's pausing to respect Slack's quotas rather than failing.

## Summary

- SlackBot enforces rate limits at two layers: per-channel/workspace and per-method tier
- Requests queue automatically instead of failing immediately
- You can observe limiter behavior via Telemetry
- Defaults work for most bots; override only when you have specific needs

## Next Steps

- [Telemetry Guide](telemetry_dashboard.md) — wire limiter events to LiveDashboard
- [Diagnostics Guide](diagnostics.md) — correlate rate-limit events with captured payloads
