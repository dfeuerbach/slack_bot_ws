defmodule SlackBot do
  @moduledoc """
  Public entry point and supervision helpers for SlackBot.

  Typical usage:

      children = [
        {SlackBot,
         app_token: System.fetch_env!("SLACK_APP_TOKEN"),
         bot_token: System.fetch_env!("SLACK_BOT_TOKEN"),
         module: MyBot}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  Pass a `:name` option when you need multiple SlackBot instances under the same
  BEAM node. Derived supervisors (config server, runtime supervisor) inherit
  names from that base.
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
  Sends a Web API request using the bot token.
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
  Sends a Web API request asynchronously using the runtime task supervisor.
  """
  @spec push_async(GenServer.server(), {String.t(), map()}) :: Task.t()
  def push_async(server \\ __MODULE__, request) do
    server
    |> resolve_task_supervisor()
    |> Task.Supervisor.async(fn -> push(server, request) end)
  end

  @doc """
  Injects a synthetic event into the handler pipeline.
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
  Finds a cached Slack user for the given bot instance.

  Matchers:

    * `{:id, "U123"}` – returns the cached payload for the exact Slack user ID.
    * `{:email, "user@example.com"}` – matches against the cached profile email (case-insensitive).
    * `{:name, "alice"}` – matches the legacy username or profile display name (case-insensitive).

  ## Examples

      iex> MyBot.find_user({:name, "alice"})
      %{"id" => "U123", "name" => "alice", ...}
  """
  @spec find_user(GenServer.server(), user_matcher) :: map() | nil
  def find_user(server \\ __MODULE__, matcher) do
    Cache.find_user(server, matcher)
  end

  @doc """
  Finds multiple cached Slack users in one call.

  Returns a map from matcher -> user map. Set `include_missing?: true` to include entries for
  matchers that currently miss the cache (with a `nil` value).

  ## Examples

      iex> MyBot.find_users([{:name, "alice"}, {:name, "bob"}])
      %{
        {:name, "alice"} => %{"id" => "U1"},
        {:name, "bob"} => %{"id" => "U2"}
      }
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
  Finds a cached Slack channel for the given bot instance.

  Matchers:

    * `{:id, "C123"}` – returns the cached channel payload for the exact Slack channel ID.
    * `{:name, "#general"}` / `{:name, "general"}` – case-insensitive name lookup (leading `#`
      optional).

  ## Examples

      iex> MyBot.find_channel({:name, "#fp-atlas"})
      %{"id" => "C42", "name" => "fp-atlas", ...}
  """
  @spec find_channel(GenServer.server(), channel_matcher) :: map() | nil
  def find_channel(server \\ __MODULE__, matcher) do
    Cache.find_channel(server, matcher)
  end

  @doc """
  Finds multiple cached Slack channels in one call.

  Behaves like `find_users/3`, returning a map of matcher -> channel map (or `nil` when
  `include_missing?: true`).
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
