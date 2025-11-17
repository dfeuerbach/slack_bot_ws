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
  Reloads configuration overrides at runtime.
  """
  @spec reload_config(keyword(), GenServer.server()) :: :ok | {:error, term()}
  def reload_config(overrides, server \\ __MODULE__) when is_list(overrides) do
    server
    |> resolve_config_server()
    |> ConfigServer.reload(overrides)
  end

  @doc """
  Sends a Web API request using the bot token.
  """
  @spec push(GenServer.server(), {String.t(), map()}) :: {:ok, map()} | {:error, term()}
  def push(server \\ __MODULE__, {method, body}) when is_binary(method) and is_map(body) do
    config = config(server)
    config.http_client.post(method, config.bot_token, body)
  end

  @doc """
  Injects a synthetic event into the handler pipeline.
  """
  @spec emit(GenServer.server(), {String.t(), map()}) :: :ok
  def emit(server \\ __MODULE__, {type, payload}) when is_binary(type) and is_map(payload) do
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
end
