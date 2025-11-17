defmodule SlackBot.Cache do
  @moduledoc """
  Facade for cache provider/mutation queue pair.
  """

  alias SlackBot.Cache.Provider
  alias SlackBot.Cache.MutationQueue

  @type cache_op ::
          {:join_channel, String.t()}
          | {:leave_channel, String.t()}
          | {:put_user, map()}
          | {:put_metadata, map()}

  @spec child_specs(SlackBot.Config.t()) :: [Supervisor.child_spec()]
  def child_specs(config) do
    provider_name = provider_name(config.instance_name)
    mutation_name = mutation_name(config.instance_name)

    [
      %{
        id: provider_name,
        start: {Provider, :start_link, [[name: provider_name]]},
        type: :worker
      },
      %{
        id: mutation_name,
        start: {MutationQueue, :start_link, [[name: mutation_name, provider: provider_name]]},
        type: :worker
      }
    ]
  end

  @spec channels(SlackBot.Config.t() | atom()) :: [String.t()]
  def channels(config_or_name) do
    provider_name(config_or_name)
    |> GenServer.call(:channels)
  end

  @spec users(SlackBot.Config.t() | atom()) :: map()
  def users(config_or_name) do
    provider_name(config_or_name)
    |> GenServer.call(:users)
  end

  @spec join_channel(SlackBot.Config.t(), String.t()) :: :ok
  def join_channel(config, channel) do
    enqueue(config, {:join_channel, channel})
  end

  @spec leave_channel(SlackBot.Config.t(), String.t()) :: :ok
  def leave_channel(config, channel) do
    enqueue(config, {:leave_channel, channel})
  end

  @spec put_user(SlackBot.Config.t(), map()) :: :ok
  def put_user(config, user) do
    enqueue(config, {:put_user, user})
  end

  @spec put_metadata(SlackBot.Config.t(), map()) :: :ok
  def put_metadata(config, metadata) when is_map(metadata) do
    enqueue(config, {:put_metadata, metadata})
  end

  defp enqueue(%{instance_name: instance}, op) do
    mutation_name(instance)
    |> GenServer.call({:mutate, op})
  end

  defp provider_name(%SlackBot.Config{instance_name: instance}), do: provider_name(instance)

  defp provider_name(name) when is_atom(name) do
    Module.concat(name, :CacheProvider)
  end

  defp mutation_name(name) when is_atom(name) do
    Module.concat(name, :CacheMutations)
  end
end
