defmodule SlackBot.Cache.Adapters.ETS do
  @moduledoc false

  @behaviour SlackBot.Cache.Adapter

  alias SlackBot.Cache.MutationQueue
  alias SlackBot.Cache.Provider
  alias SlackBot.Config

  @impl true
  def child_specs(%Config{instance_name: instance}, _opts) do
    provider_name = provider_name(instance)
    mutation_name = mutation_name(instance)

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

  defp provider_name(instance) when is_atom(instance) do
    Module.concat(instance, :CacheProvider)
  end

  defp mutation_name(instance) when is_atom(instance) do
    Module.concat(instance, :CacheMutations)
  end
end
