defmodule SlackBot.RuntimeSupervisor do
  @moduledoc false

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

    config = ConfigServer.config(config_server)

    task_supervisor_name = Module.concat(base_name, :TaskSupervisor)
    connection_manager_name = Module.concat(base_name, :ConnectionManager)
    ack_pool_name = Module.concat(base_name, :AckFinch)
    api_pool_name = Module.concat(base_name, :APIFinch)
    api_pool_opts = Keyword.put(config.api_pool_opts, :name, api_pool_name)

    children =
      [
        # Start Finch pools first so dependent workers (cache sync, cache, etc.) can push immediately.
        {Finch, name: ack_pool_name},
        {Finch, api_pool_opts}
      ]
      |> Kernel.++(SlackBot.Cache.child_specs(config))
      |> Kernel.++(tier_limiter_child_specs(config))
      |> Kernel.++(rate_limiter_child_specs(config))
      |> Kernel.++([SlackBot.EventBuffer.child_spec(config)])
      |> Kernel.++(cache_sync_child_specs(config, base_name, config_server))
      |> Kernel.++([SlackBot.Diagnostics.child_spec(config)])
      |> Kernel.++([
        %{
          id: task_supervisor_name,
          start: {Task.Supervisor, :start_link, [[name: task_supervisor_name]]},
          type: :supervisor
        },
        {SlackBot.ConnectionManager,
         name: connection_manager_name,
         config_server: config_server,
         task_supervisor: task_supervisor_name},
        {SlackBot.HealthMonitor,
         name: Module.concat(base_name, :HealthMonitor),
         config_server: config_server,
         connection_manager: connection_manager_name}
      ])

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 10, max_seconds: 60)
  end

  defp rate_limiter_child_specs(%SlackBot.Config{rate_limiter: :none}), do: []

  defp rate_limiter_child_specs(%SlackBot.Config{} = config) do
    [SlackBot.RateLimiter.child_spec(config)]
  end

  defp tier_limiter_child_specs(%SlackBot.Config{} = config) do
    [SlackBot.TierLimiter.child_spec(config)]
  end

  defp cache_sync_child_specs(
         %SlackBot.Config{cache_sync: %{enabled: false}},
         _base_name,
         _config
       ),
       do: []

  defp cache_sync_child_specs(%SlackBot.Config{cache_sync: cache_sync}, base_name, config_server) do
    if cache_sync.enabled do
      name = Module.concat(base_name, CacheSyncSupervisor)

      [
        %{
          id: name,
          start:
            {SlackBot.Cache.Sync, :start_link,
             [[name: name, config_server: config_server, base_name: base_name]]},
          type: :supervisor
        }
      ]
    else
      []
    end
  end
end
