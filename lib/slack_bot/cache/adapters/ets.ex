defmodule SlackBot.Cache.Adapters.ETS do
  @moduledoc false

  @behaviour SlackBot.Cache.Adapter

  alias SlackBot.Cache.Janitor
  alias SlackBot.Cache.MutationQueue
  alias SlackBot.Cache.Provider
  alias SlackBot.Config

  @impl true
  def child_specs(%Config{instance_name: instance} = config, _opts) do
    provider_name = provider_name(instance)
    mutation_name = mutation_name(instance)
    janitor_name = janitor_name(instance)
    cleanup_interval = config.user_cache.cleanup_interval_ms

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
      },
      %{
        id: janitor_name,
        start:
          {Janitor, :start_link,
           [[name: janitor_name, provider: provider_name, interval_ms: cleanup_interval]]},
        type: :worker
      }
    ]
  end

  @impl true
  def channels(%Config{instance_name: instance}, _opts) do
    instance
    |> provider_name()
    |> GenServer.call(:channels)
  end

  @impl true
  def users(%Config{instance_name: instance}, _opts) do
    instance
    |> provider_name()
    |> GenServer.call(:users)
  end

  @impl true
  def metadata(%Config{instance_name: instance}, _opts) do
    instance
    |> provider_name()
    |> GenServer.call(:metadata)
  end

  @impl true
  def mutate(%Config{instance_name: instance}, opts, op) do
    queue = mutation_name(instance)

    case Keyword.get(opts, :mode, :sync) do
      :async ->
        GenServer.cast(queue, {:mutate, op})
        :ok

      _ ->
        GenServer.call(queue, {:mutate, op})
    end
  end

  @impl true
  def user_entry(%Config{instance_name: instance}, _opts, user_id) do
    instance
    |> provider_name()
    |> GenServer.call({:user_entry, user_id})
  end

  defp provider_name(instance) when is_atom(instance) do
    Module.concat(instance, :CacheProvider)
  end

  defp mutation_name(instance) when is_atom(instance) do
    Module.concat(instance, :CacheMutations)
  end

  defp janitor_name(instance) when is_atom(instance) do
    Module.concat(instance, :CacheJanitor)
  end
end
