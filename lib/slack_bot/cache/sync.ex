defmodule SlackBot.Cache.Sync do
  @moduledoc false

  # Supervisor that starts per-kind cache sync workers so throttling one Slack API
  # does not pause the other.

  use Supervisor

  alias SlackBot.Cache.Sync.Users
  alias SlackBot.Cache.Sync.Channels
  alias SlackBot.ConfigServer

  @type option ::
          {:name, Supervisor.name()}
          | {:config_server, GenServer.server()}
          | {:base_name, atom()}

  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    config_server = Keyword.fetch!(opts, :config_server)
    base_name = Keyword.fetch!(opts, :base_name)

    cache_sync = ConfigServer.config(config_server).cache_sync

    if cache_sync.enabled do
      children =
        []
        |> with_users_worker(cache_sync.kinds, base_name, config_server)
        |> with_channels_worker(cache_sync.kinds, base_name, config_server)

      if children == [] do
        :ignore
      else
        Supervisor.init(children, strategy: :one_for_one)
      end
    else
      :ignore
    end
  end

  defp with_users_worker(children, kinds, base_name, config_server) do
    if :users in kinds do
      name = Module.concat(base_name, SyncUsers)

      children ++
        [
          %{
            id: name,
            start: {Users, :start_link, [[name: name, config_server: config_server]]},
            type: :worker
          }
        ]
    else
      children
    end
  end

  defp with_channels_worker(children, kinds, base_name, config_server) do
    if :channels in kinds do
      name = Module.concat(base_name, SyncChannels)

      children ++
        [
          %{
            id: name,
            start: {Channels, :start_link, [[name: name, config_server: config_server]]},
            type: :worker
          }
        ]
    else
      children
    end
  end
end
