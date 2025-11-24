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

  alias SlackBot.Config
  alias SlackBot.ConfigServer
  alias SlackBot.ConnectionManager
  alias SlackBot.Diagnostics
  alias SlackBot.Telemetry

  @reserved_supervisor_opts [:name, :config_server, :runtime_supervisor]

  @doc """
  Starts a SlackBot supervision tree.

  Accepts the same options as `c:child_spec/1`, returning `Supervisor.on_start/2`.
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
    config = config(server)

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
