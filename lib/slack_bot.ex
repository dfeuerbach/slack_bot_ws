defmodule SlackBot do
  @moduledoc """
  Production-ready Slack bot framework for Socket Mode.

  SlackBot provides a supervised WebSocket connection, tier-aware rate limiting,
  declarative slash-command parsing, and full observability for building Slack bots
  in Elixir.

  ## Quick Start

  The recommended approach is the `otp_app` pattern:

  **1. Define your bot module:**

      defmodule MyApp.SlackBot do
        use SlackBot, otp_app: :my_app

        handle_event "message", event, _ctx do
          SlackBot.push({"chat.postMessage", %{
            "channel" => event["channel"],
            "text" => "Hello from MyApp!"
          }})
        end

        slash "/ping" do
          grammar do
            # Empty grammar matches just "/ping"
          end

          handle _payload, _ctx do
            {:ok, %{"text" => "Pong!"}}
          end
        end
      end

  **2. Configure tokens:**

      # config/config.exs
      config :my_app, MyApp.SlackBot,
        app_token: System.fetch_env!("SLACK_APP_TOKEN"),
        bot_token: System.fetch_env!("SLACK_BOT_TOKEN")

  **3. Supervise:**

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            MyApp.SlackBot
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  ## Alternative: Inline Supervision

  You can also supervise SlackBot directly without the `otp_app` pattern:

      children = [
        {SlackBot,
         name: MyBot,
         app_token: System.fetch_env!("SLACK_APP_TOKEN"),
         bot_token: System.fetch_env!("SLACK_BOT_TOKEN"),
         module: MyBot}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  This approach is useful for dynamic bot instances or when you prefer explicit
  configuration over application environment.

  ## Public API

  ### Web API Calls

  - `push/2` - Synchronous API call (waits for response)
  - `push_async/2` - Fire-and-forget async call

  Both route through rate limiters and Telemetry automatically.

  ### Cache Queries

  - `find_user/2` - Lookup cached users by ID, email, or name
  - `find_users/3` - Batch user lookup
  - `find_channel/2` - Lookup channels by ID or name
  - `find_channels/3` - Batch channel lookup

  ### Event Injection

  - `emit/2` - Inject synthetic events into the handler pipeline

  ### Configuration

  - `config/1` - Read the immutable `%SlackBot.Config{}` struct

  ## Multiple Bot Instances

  Run multiple bots in the same BEAM node by giving each a unique name:

      children = [
        {SlackBot, name: BotOne, module: MyApp.BotOne, ...},
        {SlackBot, name: BotTwo, module: MyApp.BotTwo, ...}
      ]

  Derived processes (config server, connection manager, task supervisor) inherit
  names automatically: `BotOne.ConfigServer`, `BotOne.ConnectionManager`, etc.

  ## See Also

  - [Getting Started Guide](https://hexdocs.pm/slack_bot_ws/getting_started.html)
  - [Rate Limiting Guide](https://hexdocs.pm/slack_bot_ws/rate_limiting.html)
  - [Slash Grammar Guide](https://hexdocs.pm/slack_bot_ws/slash_grammar.html)
  - [Telemetry Dashboard](https://hexdocs.pm/slack_bot_ws/telemetry_dashboard.html)
  - `BasicBot` - Complete working example
  """

  alias SlackBot.Cache
  alias SlackBot.Config
  alias SlackBot.ConfigServer
  alias SlackBot.ConnectionManager
  alias SlackBot.Diagnostics
  alias SlackBot.RateLimiter
  alias SlackBot.Telemetry

  @typedoc """
  Criteria for matching cached Slack users.
  """
  @type user_matcher :: {:id, String.t()} | {:email, String.t()} | {:name, String.t()}

  @typedoc """
  Criteria for matching cached Slack channels.
  """
  @type channel_matcher :: {:id, String.t()} | {:name, String.t()}

  @reserved_supervisor_opts [:name, :config_server, :runtime_supervisor]

  @doc """
  Starts a SlackBot supervision tree.

  Accepts the same options as `child_spec/1`, returning `Supervisor.on_start()`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {supervisor_opts, config_opts} = split_opts(opts)
    supervisor_opts = Keyword.put(supervisor_opts, :config, config_opts)

    SlackBot.Supervisor.start_link(supervisor_opts)
  end

  @doc """
  Returns a child specification so SlackBot can be supervised directly.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    {supervisor_opts, config_opts} = split_opts(opts)
    supervisor_opts = Keyword.put(supervisor_opts, :config, config_opts)

    id =
      Keyword.get_lazy(supervisor_opts, :name, fn ->
        {:slack_bot, Keyword.get(config_opts, :module, __MODULE__)}
      end)

    %{
      id: id,
      start: {SlackBot.Supervisor, :start_link, [supervisor_opts]},
      type: :supervisor
    }
  end

  @doc """
  Reads the immutable `%SlackBot.Config{}` from the config server registered under `server`.
  """
  @spec config(GenServer.server()) :: Config.t()
  def config(server \\ __MODULE__) do
    server
    |> resolve_config_server()
    |> ConfigServer.config()
  end

  @doc """
  Sends a Web API request to Slack using the bot token.

  This is your primary way to call Slack's Web API. SlackBot automatically:

  - Routes through per-channel and tier-level rate limiters
  - Emits Telemetry events for observability
  - Uses the configured HTTP pool (Finch by default)

  ## Arguments

  - `server` - Bot instance name (defaults to `SlackBot`)
  - `{method, body}` - Tuple of API method name and request parameters

  ## Returns

  - `{:ok, response}` - Successful API call with Slack's JSON response
  - `{:error, reason}` - Failed call (see Error Handling below)

  ## Examples

  ### Post a message

      iex> SlackBot.push(MyApp.SlackBot, {"chat.postMessage", %{
      ...>   "channel" => "C123456",
      ...>   "text" => "Hello from SlackBot!",
      ...>   "blocks" => [...]
      ...> }})
      {:ok, %{
        "ok" => true,
        "channel" => "C123456",
        "ts" => "1234567890.123456",
        "message" => %{"text" => "Hello from SlackBot!", ...}
      }}

  ### Upload a file

      iex> SlackBot.push(MyApp.SlackBot, {"files.upload", %{
      ...>   "channels" => "C123456",
      ...>   "content" => "log data here",
      ...>   "filename" => "debug.log",
      ...>   "title" => "Debug Logs"
      ...> }})
      {:ok, %{"ok" => true, "file" => %{"id" => "F123", ...}}}

  ### Update a message

      iex> SlackBot.push(MyApp.SlackBot, {"chat.update", %{
      ...>   "channel" => "C123456",
      ...>   "ts" => "1234567890.123456",
      ...>   "text" => "Updated text"
      ...> }})
      {:ok, %{"ok" => true, ...}}

  ## Error Handling

      case SlackBot.push(MyApp.SlackBot, {"chat.postMessage", body}) do
        {:ok, %{"ok" => true} = response} ->
          Logger.info("Message posted: \#{response["ts"]}")

        {:ok, %{"ok" => false, "error" => error}} ->
          Logger.error("Slack API error: \#{error}")

        {:error, reason} ->
          Logger.error("HTTP error: \#{inspect(reason)}")
      end

  ## Common Errors

  - `"channel_not_found"` - Invalid channel ID or bot not invited
  - `"not_in_channel"` - Bot needs to join the channel first
  - `"invalid_auth"` - Check your bot token
  - `"rate_limited"` - You've exceeded Slack's quotas (SlackBot mitigates this)
  - `"msg_too_long"` - Message exceeds 40,000 characters

  ## Rate Limiting

  SlackBot automatically queues requests when approaching rate limits. Your call
  may block briefly if the limiter needs to wait. Use `push_async/2` for
  fire-and-forget calls that shouldn't block your handler.

  ## See Also

  - `push_async/2` - Non-blocking variant
  - [Slack Web API Reference](https://api.slack.com/methods)
  - [Rate Limiting Guide](https://hexdocs.pm/slack_bot_ws/rate_limiting.html)
  """
  @spec push(GenServer.server(), {String.t(), map()}) :: {:ok, map()} | {:error, term()}
  def push(server \\ __MODULE__, {method, body}) when is_binary(method) and is_map(body) do
    config =
      case server do
        %Config{} = config -> config
        _ -> config(server)
      end

    RateLimiter.around_request(config, method, body, fn ->
      start = System.monotonic_time()

      try do
        result = config.http_client.post(config, method, body)
        duration = System.monotonic_time() - start

        Telemetry.execute(
          config,
          [:api, :request],
          %{duration: duration},
          %{method: method, status: api_status(result)}
        )

        result
      rescue
        exception ->
          duration = System.monotonic_time() - start

          Telemetry.execute(config, [:api, :request], %{duration: duration}, %{
            method: method,
            status: :exception
          })

          reraise exception, __STACKTRACE__
      end
    end)
  end

  @doc """
  Sends a Web API request asynchronously without blocking the caller.

  Use this when you want fire-and-forget behavior—your handler continues
  immediately while the API call happens in a supervised task.

  ## When to Use push_async

  - Posting multiple messages in a loop
  - Sending notifications that don't need confirmation
  - Updating UI elements in the background
  - Any call where you don't need the response immediately

  ## Returns

  A `Task.t()` you can await later if needed, or ignore for true fire-and-forget.

  ## Examples

  ### Send multiple notifications

      def notify_team(user_ids, message) do
        Enum.each(user_ids, fn user_id ->
          SlackBot.push_async(MyApp.SlackBot, {"chat.postMessage", %{
            "channel" => user_id,
            "text" => message
          }})
        end)

        :ok  # Returns immediately, messages send in background
      end

  ### Fire and forget

      # Don't care about the result
      SlackBot.push_async(MyApp.SlackBot, {"reactions.add", %{
        "channel" => channel,
        "timestamp" => ts,
        "name" => "white_check_mark"
      }})

  ### Await if needed

      task = SlackBot.push_async(MyApp.SlackBot, {"chat.postMessage", body})
      # ... do other work ...
      result = Task.await(task, 5_000)

  ## Task Supervision

  All async tasks run under SlackBot's runtime task supervisor, so crashes won't
  take down your bot. Failed tasks are logged automatically.

  ## See Also

  - `push/2` - Synchronous variant that waits for response
  - `Task.await/2` - If you need to wait for the result later
  """
  @spec push_async(GenServer.server(), {String.t(), map()}) :: Task.t()
  def push_async(server \\ __MODULE__, request) do
    server
    |> resolve_task_supervisor()
    |> Task.Supervisor.async(fn -> push(server, request) end)
  end

  @doc """
  Injects a synthetic event into your handler pipeline.

  This lets you programmatically trigger handlers as if Slack sent the event,
  useful for testing, scheduled tasks, or cross-bot communication.

  ## Use Cases

  - **Testing**: Replay production events in development
  - **Scheduled jobs**: Trigger handlers from a cron-like scheduler
  - **Internal events**: Coordinate between different parts of your bot
  - **Simulations**: Test handler behavior without hitting Slack

  ## Arguments

  - `type` - Event type matching your `handle_event` declarations
  - `payload` - Event payload map (structure depends on event type)

  ## Examples

  ### Trigger a message handler

      SlackBot.emit(MyApp.SlackBot, {"message", %{
        "type" => "message",
        "channel" => "C123456",
        "user" => "U123456",
        "text" => "simulated message",
        "ts" => "1234567890.123456"
      }})

  ### Scheduled reminder

      def send_daily_reminder do
        SlackBot.emit(MyApp.SlackBot, {"daily_reminder", %{
          "time" => DateTime.utc_now(),
          "channels" => ["C123", "C456"]
        }})
      end

      # In your router:
      handle_event "daily_reminder", payload, _ctx do
        Enum.each(payload["channels"], fn channel ->
          SlackBot.push({"chat.postMessage", %{
            "channel" => channel,
            "text" => "Daily standup in 10 minutes!"
          }})
        end)
      end

  ### Test a handler

      # In your test
      test "processes mentions correctly" do
        SlackBot.emit(MyBot, {"app_mention", %{
          "channel" => "C123",
          "user" => "U123",
          "text" => "<@BOTID> help"
        }})

        # Assert side effects
        assert_receive {:message_sent, "C123", text}
      end

  ## Diagnostics

  Emitted events are recorded in the diagnostics buffer (when enabled) with
  `direction: :outbound` and `meta: %{origin: :emit}`.

  ## See Also

  - `SlackBot.Diagnostics.replay/2` - Replay captured events
  - Your `handle_event` declarations in your bot module
  """
  @spec emit(GenServer.server(), {String.t(), map()}) :: :ok
  def emit(server \\ __MODULE__, {type, payload}) when is_binary(type) and is_map(payload) do
    config = config(server)

    Diagnostics.record(config, :outbound, %{
      type: type,
      payload: payload,
      meta: %{origin: :emit}
    })

    server
    |> resolve_connection_manager()
    |> ConnectionManager.emit(type, payload)
  end

  @doc """
  Finds a cached Slack user, fetching from Slack API if not cached.

  This is your go-to function for resolving users by ID, email, or name. SlackBot
  checks the cache first, then hits Slack's API if needed, then caches the result.

  ## Matchers

  - `{:id, "U123"}` - Exact Slack user ID (fastest)
  - `{:email, "alice@example.com"}` - Profile email (case-insensitive)
  - `{:name, "alice"}` - Username or display name (case-insensitive)

  ## Returns

  - User map with full Slack profile data
  - `nil` if no matching user found

  ## Examples

  ### Find by ID (fastest)

      iex> SlackBot.find_user(MyApp.SlackBot, {:id, "U123456"})
      %{
        "id" => "U123456",
        "name" => "alice",
        "real_name" => "Alice Smith",
        "profile" => %{
          "email" => "alice@example.com",
          "display_name" => "Alice",
          "title" => "Software Engineer",
          "image_72" => "https://...",
          "status_text" => "In a meeting",
          "status_emoji" => ":calendar:"
        },
        "is_bot" => false,
        "is_admin" => false,
        "tz" => "America/Los_Angeles"
      }

  ### Find by email

      iex> SlackBot.find_user(MyApp.SlackBot, {:email, "bob@example.com"})
      %{"id" => "U789", "name" => "bob", ...}

      iex> SlackBot.find_user(MyApp.SlackBot, {:email, "nobody@example.com"})
      nil

  ### Find by name

      # Matches username
      iex> SlackBot.find_user(MyApp.SlackBot, {:name, "alice"})
      %{"id" => "U123", "name" => "alice", ...}

      # Also matches display name
      iex> SlackBot.find_user(MyApp.SlackBot, {:name, "Alice Smith"})
      %{"id" => "U123", "profile" => %{"display_name" => "Alice Smith"}, ...}

  ## Practical Usage

      def send_dm(email, message) do
        case SlackBot.find_user(MyBot, {:email, email}) do
          %{"id" => user_id} ->
            SlackBot.push(MyBot, {"chat.postMessage", %{
              "channel" => user_id,
              "text" => message
            }})

          nil ->
            {:error, :user_not_found}
        end
      end

  ## Caching Behavior

  - First lookup fetches from Slack and caches (respects `user_cache.ttl_ms`)
  - Subsequent lookups are instant from cache
  - Cache auto-refreshes on expiry

  ## Performance Tips

  - Prefer `{:id, ...}` when you have the ID—it's a direct cache lookup
  - Use `find_users/3` for batch lookups to reduce API calls
  - Email and name matchers scan the cache first before hitting the API

  ## See Also

  - `find_users/3` - Batch lookup multiple users at once
  - `find_channel/2` - Similar function for channels
  """
  @spec find_user(GenServer.server(), user_matcher) :: map() | nil
  def find_user(server \\ __MODULE__, matcher) do
    Cache.find_user(server, matcher)
  end

  @doc """
  Finds multiple cached Slack users in a single batch operation.

  More efficient than calling `find_user/2` in a loop—reduces API calls and gives
  you a convenient map of results keyed by your original matchers.

  ## Arguments

  - `matchers` - List of user matchers (same format as `find_user/2`)
  - `opts` - Options:
    - `include_missing?: false` - Set true to include `nil` entries for users not found

  ## Returns

  Map from matcher to user data (or `nil` when `include_missing?: true`)

  ## Examples

  ### Lookup team members

      iex> team_emails = ["alice@ex.com", "bob@ex.com", "carol@ex.com"]
      iex> matchers = Enum.map(team_emails, &{:email, &1})
      iex> SlackBot.find_users(MyApp.SlackBot, matchers)
      %{
        {:email, "alice@ex.com"} => %{"id" => "U1", "name" => "alice", ...},
        {:email, "bob@ex.com"} => %{"id" => "U2", "name" => "bob", ...},
        {:email, "carol@ex.com"} => %{"id" => "U3", "name" => "carol", ...}
      }

  ### Include missing users

      iex> SlackBot.find_users(MyApp.SlackBot,
      ...>   [{:email, "exists@ex.com"}, {:email, "nope@ex.com"}],
      ...>   include_missing?: true
      ...> )
      %{
        {:email, "exists@ex.com"} => %{"id" => "U1", ...},
        {:email, "nope@ex.com"} => nil
      }

  ### Practical: Notify multiple users

      def notify_users(emails, message) do
        matchers = Enum.map(emails, &{:email, &1})
        users = SlackBot.find_users(MyBot, matchers)

        results =
          Enum.map(users, fn {_matcher, user} ->
            SlackBot.push(MyBot, {"chat.postMessage", %{
              "channel" => user["id"],
              "text" => message
            }})
          end)

        {:ok, length(results)}
      end

  ### Extract user IDs

      users = SlackBot.find_users(MyBot, matchers)
      user_ids = Enum.map(users, fn {_k, v} -> v["id"] end)

  ## Performance

  This is much faster than a loop of `find_user/2` calls because it:

  - Batches cache lookups
  - Reduces individual API calls
  - Returns all results at once

  ## See Also

  - `find_user/2` - Single user lookup
  - `find_channels/3` - Batch channel lookup
  """
  @spec find_users(GenServer.server(), [user_matcher], keyword()) ::
          %{optional(user_matcher) => map() | nil}
  def find_users(server \\ __MODULE__, matchers, opts \\ []) when is_list(matchers) do
    include_missing? = Keyword.get(opts, :include_missing?, false)

    Enum.reduce(matchers, %{}, fn matcher, acc ->
      case find_user(server, matcher) do
        nil when include_missing? -> Map.put(acc, matcher, nil)
        nil -> acc
        user -> Map.put(acc, matcher, user)
      end
    end)
  end

  @doc """
  Finds a cached Slack channel, fetching from Slack API if not cached.

  Returns the full channel object including name, topic, member count, and metadata.
  Checks cache first, then hits Slack's API if needed.

  ## Matchers

  - `{:id, "C123"}` - Exact channel ID (fastest)
  - `{:name, "#general"}` - Channel name with or without `#` (case-insensitive)
  - `{:name, "general"}` - Same as above

  ## Returns

  - Channel map with full Slack channel data
  - `nil` if no matching channel found or bot not a member

  ## Examples

  ### Find by ID

      iex> SlackBot.find_channel(MyApp.SlackBot, {:id, "C123456"})
      %{
        "id" => "C123456",
        "name" => "general",
        "is_channel" => true,
        "is_private" => false,
        "is_archived" => false,
        "topic" => %{
          "value" => "Company announcements",
          "creator" => "U123",
          "last_set" => 1234567890
        },
        "purpose" => %{
          "value" => "This channel is for team-wide communication"
        },
        "num_members" => 150,
        "created" => 1234567890
      }

  ### Find by name

      # With hash
      iex> SlackBot.find_channel(MyApp.SlackBot, {:name, "#engineering"})
      %{"id" => "C789", "name" => "engineering", ...}

      # Without hash (same result)
      iex> SlackBot.find_channel(MyApp.SlackBot, {:name, "engineering"})
      %{"id" => "C789", "name" => "engineering", ...}

      # Not found
      iex> SlackBot.find_channel(MyApp.SlackBot, {:name, "#nonexistent"})
      nil

  ## Practical Usage

      def post_to_channel(channel_name, message) do
        case SlackBot.find_channel(MyBot, {:name, channel_name}) do
          %{"id" => channel_id} ->
            SlackBot.push(MyBot, {"chat.postMessage", %{
              "channel" => channel_id,
              "text" => message
            }})

          nil ->
            {:error, :channel_not_found}
        end
      end

  ## Important: Bot Membership

  The bot must be a member of a channel to find it. Private channels won't appear
  unless the bot has been invited.

  ## Caching Behavior

  - Channel cache syncs automatically (see `cache_sync` config)
  - Default sync runs hourly via `conversations.list`
  - Sync only includes channels the bot has joined

  ## Performance Tips

  - Prefer `{:id, ...}` when you have the ID
  - Use `find_channels/3` for batch lookups
  - Name lookups scan the cache (no extra API call once synced)

  ## See Also

  - `find_channels/3` - Batch channel lookup
  - `find_user/2` - Similar function for users
  - Config option `cache_sync` - Controls channel cache refresh
  """
  @spec find_channel(GenServer.server(), channel_matcher) :: map() | nil
  def find_channel(server \\ __MODULE__, matcher) do
    Cache.find_channel(server, matcher)
  end

  @doc """
  Finds multiple cached Slack channels in a single batch operation.

  Like `find_users/3` but for channels—more efficient than looping `find_channel/2`.

  ## Arguments

  - `matchers` - List of channel matchers (same format as `find_channel/2`)
  - `opts` - Options:
    - `include_missing?: false` - Set true to include `nil` entries for channels not found

  ## Returns

  Map from matcher to channel data (or `nil` when `include_missing?: true`)

  ## Examples

  ### Find multiple channels

      iex> SlackBot.find_channels(MyApp.SlackBot, [
      ...>   {:name, "#general"},
      ...>   {:name, "#engineering"},
      ...>   {:id, "C789"}
      ...> ])
      %{
        {:name, "#general"} => %{"id" => "C123", "name" => "general", ...},
        {:name, "#engineering"} => %{"id" => "C456", "name" => "engineering", ...},
        {:id, "C789"} => %{"id" => "C789", "name" => "random", ...}
      }

  ### Post to multiple channels

      def broadcast_announcement(channel_names, message) do
        matchers = Enum.map(channel_names, &{:name, &1})
        channels = SlackBot.find_channels(MyBot, matchers)

        Enum.each(channels, fn {_matcher, channel} ->
          SlackBot.push_async(MyBot, {"chat.postMessage", %{
            "channel" => channel["id"],
            "text" => message
          }})
        end)

        {:ok, map_size(channels)}
      end

  ### Extract channel IDs

      channels = SlackBot.find_channels(MyBot, matchers)
      channel_ids = Enum.map(channels, fn {_k, v} -> v["id"] end)

  ## See Also

  - `find_channel/2` - Single channel lookup
  - `find_users/3` - Batch user lookup
  """
  @spec find_channels(GenServer.server(), [channel_matcher], keyword()) ::
          %{optional(channel_matcher) => map() | nil}
  def find_channels(server \\ __MODULE__, matchers, opts \\ []) when is_list(matchers) do
    include_missing? = Keyword.get(opts, :include_missing?, false)

    Enum.reduce(matchers, %{}, fn matcher, acc ->
      case find_channel(server, matcher) do
        nil when include_missing? -> Map.put(acc, matcher, nil)
        nil -> acc
        channel -> Map.put(acc, matcher, channel)
      end
    end)
  end

  defp split_opts(opts) do
    supervisor_opts = Keyword.take(opts, @reserved_supervisor_opts)
    config_opts = Keyword.drop(opts, @reserved_supervisor_opts)
    {supervisor_opts, config_opts}
  end

  defp resolve_config_server(server) when is_atom(server) or is_tuple(server) or is_pid(server) do
    resolve_child_name(server, :ConfigServer)
  end

  defp resolve_connection_manager(server)
       when is_atom(server) or is_tuple(server) or is_pid(server) do
    resolve_child_name(server, :ConnectionManager)
  end

  defp resolve_task_supervisor(server)
       when is_atom(server) or is_tuple(server) or is_pid(server) do
    resolve_child_name(server, :TaskSupervisor)
  end

  defp resolve_child_name({:via, _, _} = via, _suffix), do: via
  defp resolve_child_name(pid, _suffix) when is_pid(pid), do: pid

  defp resolve_child_name(name, suffix) when is_atom(name) do
    suffix_str = Atom.to_string(suffix)
    string = Atom.to_string(name)

    if String.ends_with?(string, suffix_str) do
      name
    else
      Module.concat(name, suffix)
    end
  end

  defmacro __using__(opts \\ []) do
    otp_app = Keyword.get(opts, :otp_app)
    router_opts = Keyword.delete(opts, :otp_app)

    quote bind_quoted: [router_opts: router_opts, otp_app: otp_app] do
      use SlackBot.Router, router_opts

      @doc false
      @spec find_user(SlackBot.user_matcher()) :: map() | nil
      def find_user(matcher), do: SlackBot.find_user(__MODULE__, matcher)

      @doc false
      @spec find_users([SlackBot.user_matcher()], keyword()) ::
              %{optional(SlackBot.user_matcher()) => map() | nil}
      def find_users(matchers, opts \\ []),
        do: SlackBot.find_users(__MODULE__, matchers, opts)

      @doc false
      @spec find_channel(SlackBot.channel_matcher()) :: map() | nil
      def find_channel(matcher), do: SlackBot.find_channel(__MODULE__, matcher)

      @doc false
      @spec find_channels([SlackBot.channel_matcher()], keyword()) ::
              %{optional(SlackBot.channel_matcher()) => map() | nil}
      def find_channels(matchers, opts \\ []),
        do: SlackBot.find_channels(__MODULE__, matchers, opts)

      if otp_app do
        @slackbot_otp_app otp_app

        @doc false
        @spec child_spec(keyword()) :: Supervisor.child_spec()
        def child_spec(opts \\ []) do
          env_opts = Application.get_env(@slackbot_otp_app, __MODULE__, [])

          full_opts =
            env_opts
            |> Keyword.put_new(:name, __MODULE__)
            |> Keyword.put_new(:module, __MODULE__)
            |> Keyword.merge(opts)

          SlackBot.child_spec(full_opts)
        end
      end
    end
  end

  defp api_status({:ok, _}), do: :ok
  defp api_status({:error, _}), do: :error
  defp api_status(_), do: :unknown
end
