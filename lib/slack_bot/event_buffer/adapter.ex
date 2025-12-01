defmodule SlackBot.EventBuffer.Adapter do
  @moduledoc """
  Behaviour for pluggable event buffer backends.

  The event buffer tracks envelope IDs from Slack's Socket Mode stream to ensure
  exactly-once processing. Each envelope gets recorded when received, preventing
  duplicate handler execution if Slack retransmits.

  ## Why Custom Adapters?

  The default ETS adapter works perfectly for single-node bots. Implement this
  behaviour when:

  - **Running multiple bot instances** - Coordinate dedupe across nodes
  - **High-availability deployments** - Ensure exactly-once semantics during failover
  - **Audit requirements** - Persist envelope history for compliance
  - **Existing infrastructure** - Integrate with your Redis, DynamoDB, etc.

  ## Adapter Contract

  ### Deduplication Flow

  1. Socket Mode delivers envelope with `envelope_id`
  2. Bot calls `record/3` with the ID
  3. Adapter returns `:ok` (new) or `:duplicate` (seen before)
  4. Bot only dispatches handlers for `:ok` envelopes

  ### Critical Requirement

  `record/3` **must be atomic**. The check-and-insert must happen in a single
  operation to prevent race conditions when multiple processes receive the same
  envelope.

  ## Example: Redis Adapter

      defmodule MyApp.RedisEventBuffer do
        @behaviour SlackBot.EventBuffer.Adapter

        def init(opts) do
          redis_opts = Keyword.get(opts, :redis, [])
          case Redix.start_link(redis_opts) do
            {:ok, conn} -> {:ok, conn}
            error -> error
          end
        end

        def record(conn, envelope_id, envelope) do
          key = "slackbot:envelope:\#{envelope_id}"
          ttl = 3600  # Keep for 1 hour

          # Atomic SET NX (set if not exists)
          case Redix.command(conn, ["SET", key, Jason.encode!(envelope), "EX", ttl, "NX"]) do
            {:ok, "OK"} -> {:ok, conn}
            {:ok, nil} -> {:duplicate, conn}
          end
        end

        def seen?(conn, envelope_id) do
          key = "slackbot:envelope:\#{envelope_id}"
          case Redix.command(conn, ["EXISTS", key]) do
            {:ok, 1} -> {true, conn}
            {:ok, 0} -> {false, conn}
          end
        end

        # ... implement remaining callbacks
      end

  Then configure:

      config :my_app, MyApp.SlackBot,
        event_buffer: {:adapter, MyApp.RedisEventBuffer,
          redis: [host: "redis.example.com"]}

  ## Included Adapters

  - **ETS** (default) - Fast, single-node, zero external dependencies
  - `SlackBot.EventBuffer.Adapters.Redis` - Multi-node, production-ready

  ## See Also

  - `SlackBot.EventBuffer.Adapters.Redis` - Documented Redis implementation you can copy/customize
  - `SlackBot.Cache.Adapter` - Similar behaviour for metadata cache
  - [Source on GitHub](https://github.com/dfeuerbach/slack_bot_ws/tree/master/lib/slack_bot/event_buffer/adapters) - Reference implementations
  """

  @callback init(keyword()) :: {:ok, term()}
  @callback record(term(), String.t(), map()) :: {:ok | :duplicate, term()}
  @callback delete(term(), String.t()) :: {:ok, term()}
  @callback seen?(term(), String.t()) :: {boolean(), term()}
  @callback pending(term()) :: {list(), term()}
end
