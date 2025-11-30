defmodule SlackBot.Supervisor do
  @moduledoc false

  use Supervisor

  alias SlackBot.ConfigServer

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    opts = Keyword.put(opts, :supervisor_name, name)

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    supervisor_name = Keyword.fetch!(opts, :supervisor_name)

    config_opts =
      opts
      |> Keyword.get(:config, [])
      |> Keyword.put(:instance_name, supervisor_name)

    config_server_name =
      Keyword.get(opts, :config_server, Module.concat(supervisor_name, :ConfigServer))

    runtime_supervisor_name =
      Keyword.get(opts, :runtime_supervisor, Module.concat(supervisor_name, :RuntimeSupervisor))

    runtime_opts = [
      name: runtime_supervisor_name,
      base_name: supervisor_name,
      config_server: config_server_name
    ]

    children = [
      {ConfigServer, name: config_server_name, config: config_opts},
      {SlackBot.RuntimeSupervisor, runtime_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
