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
  def config(server \\ SlackBot.ConfigServer) do
    ConfigServer.config(server)
  end

  @doc """
  Reloads configuration overrides at runtime.
  """
  @spec reload_config(keyword(), GenServer.server()) :: :ok | {:error, term()}
  def reload_config(overrides, server \\ SlackBot.ConfigServer) when is_list(overrides) do
    ConfigServer.reload(overrides, server)
  end

  defp split_opts(opts) do
    supervisor_opts = Keyword.take(opts, @reserved_supervisor_opts)
    config_opts = Keyword.drop(opts, @reserved_supervisor_opts)
    {supervisor_opts, config_opts}
  end
end
