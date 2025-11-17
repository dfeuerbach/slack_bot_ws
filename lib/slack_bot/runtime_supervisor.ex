defmodule SlackBot.RuntimeSupervisor do
  @moduledoc """
  Supervisor that owns runtime processes (connection manager, task supervisors, etc.).
  """

  use Supervisor

  alias SlackBot.ConfigServer

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    opts = Keyword.put(opts, :runtime_name, name)

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    _runtime_name = Keyword.fetch!(opts, :runtime_name)
    base_name = Keyword.fetch!(opts, :base_name)
    config_server = Keyword.fetch!(opts, :config_server)

    _config = ConfigServer.config(config_server)

    task_supervisor_name = Module.concat(base_name, :TaskSupervisor)
    connection_manager_name = Module.concat(base_name, :ConnectionManager)

    children = [
      %{
        id: task_supervisor_name,
        start: {Task.Supervisor, :start_link, [[name: task_supervisor_name]]},
        type: :supervisor
      },
      {SlackBot.ConnectionManager,
       name: connection_manager_name,
       config_server: config_server,
       task_supervisor: task_supervisor_name}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 10_000, max_seconds: 60)
  end
end
