defmodule SlackBot.Cache do
  @moduledoc """
  Public API for SlackBot's metadata cache.

  The cache keeps lightweight snapshots of the bot's channel membership, known users,
  and other frequently accessed metadata. Reads always go through the provider
  GenServer while writes are serialized through the mutation queue, honoring the
  project's preference for Provider/Mutation patterns.
  """

  alias SlackBot.Cache.Provider
  alias SlackBot.Cache.MutationQueue

  @type cache_op ::
          {:join_channel, String.t()}
          | {:leave_channel, String.t()}
          | {:put_user, map()}
          | {:put_metadata, map()}

  @doc """
  Returns the supervision children required to run the cache provider and mutation queue.
  """
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

  @doc """
  Lists the channel IDs currently cached for the bot instance.
  """
  @spec channels(SlackBot.Config.t() | atom()) :: [String.t()]
  def channels(config_or_name) do
    provider_name(config_or_name)
    |> GenServer.call(:channels)
  end

  @doc """
  Returns a map of user_id => user_payload for cached users.
  """
  @spec users(SlackBot.Config.t() | atom()) :: map()
  def users(config_or_name) do
    provider_name(config_or_name)
    |> GenServer.call(:users)
  end

  @doc """
  Marks the bot as having joined the given `channel`.
  """
  @spec join_channel(SlackBot.Config.t(), String.t()) :: :ok
  def join_channel(config, channel) do
    enqueue(config, {:join_channel, channel})
  end

  @doc """
  Marks the bot as having left the given `channel`.
  """
  @spec leave_channel(SlackBot.Config.t(), String.t()) :: :ok
  def leave_channel(config, channel) do
    enqueue(config, {:leave_channel, channel})
  end

  @doc """
  Stores or updates a Slack user payload.
  """
  @spec put_user(SlackBot.Config.t(), map()) :: :ok
  def put_user(config, user) do
    enqueue(config, {:put_user, user})
  end

  @doc """
  Merges arbitrary metadata (team info, workspace settings, etc.) into the cache.
  """
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
