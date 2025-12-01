defmodule SlackBot.Cache.Adapter do
  @moduledoc """
  Behaviour for pluggable cache backends.

  SlackBot uses a cache to store Slack workspace metadata (users, channels) and
  telemetry snapshots. The default ETS adapter works well for single-node deployments.
  Implement this behaviour when you need:

  - **Multi-node coordination** - Share cache across multiple BEAM nodes
  - **External requirements** - Integrate with existing Redis, Postgres, etc.
  - **Custom eviction** - Implement domain-specific TTL or LRU strategies
  - **Persistence** - Survive node restarts without re-fetching from Slack

  ## When to Use Custom Adapters

  **Stick with ETS (default) when:**

  - Running a single bot process
  - Cache data can be rebuilt quickly from Slack APIs
  - You want zero external dependencies

  **Consider a custom adapter when:**

  - Running multiple bot instances that should share cache
  - You need cache persistence across restarts
  - Your infrastructure already provides Redis, Memcached, etc.
  - You want centralized observability of cache contents

  ## Implementation Requirements

  Your adapter must:

  1. Return child specs from `child_specs/2` for any processes it needs
  2. Handle all cache operations defined in the callbacks
  3. Be safe for concurrent access from multiple processes
  4. Respect the configuration passed in opts

  ## Example: Redis Adapter

      defmodule MyApp.RedisCache do
        @behaviour SlackBot.Cache.Adapter

        def child_specs(config, opts) do
          redis_opts = Keyword.get(opts, :redis, [])
          name = redis_name(config)

          [
            {Redix, [name: name] ++ redis_opts}
          ]
        end

        def channels(config, opts) do
          config
          |> redis_name()
          |> Redix.command!(["SMEMBERS", "slackbot:channels"])
        end

        def users(config, opts) do
          # Implementation: fetch user map from Redis hash
        end

        # ... implement remaining callbacks
      end

  Then configure:

      config :my_app, MyApp.SlackBot,
        cache: {:adapter, MyApp.RedisCache, redis: [host: "localhost"]}

  ## See Also

  - `SlackBot.Cache` - Public cache API for querying cached data
  - `SlackBot.EventBuffer.Adapter` - Similar behaviour for event dedupe
  - [Source on GitHub](https://github.com/dfeuerbach/slack_bot_ws/tree/master/lib/slack_bot/cache/adapters) - Reference implementations
  """

  alias SlackBot.Config

  @callback child_specs(Config.t(), keyword()) :: [Supervisor.child_spec()]
  @callback channels(Config.t(), keyword()) :: [String.t()]
  @callback users(Config.t(), keyword()) :: map()
  @callback metadata(Config.t(), keyword()) :: map()
  @callback mutate(Config.t(), keyword(), SlackBot.Cache.cache_op()) :: :ok
  @callback user_entry(Config.t(), keyword(), String.t()) ::
              {:ok, %{data: map(), expires_at: integer()}} | :not_found
end
