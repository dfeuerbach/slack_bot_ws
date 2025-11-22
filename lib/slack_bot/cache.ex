defmodule SlackBot.Cache do
  @moduledoc """
  Public API for SlackBot's metadata cache.

  The cache keeps lightweight snapshots of the bot's channel membership, known users,
  and other frequently accessed metadata. The storage backend is pluggable via adapter
  behaviours so teams can choose ETS, Redis, or their own implementation while keeping
  the public API stable.
  """

  alias SlackBot.Cache.Adapter
  alias SlackBot.Cache.Adapters.ETS

  @type cache_op ::
          {:join_channel, String.t()}
          | {:leave_channel, String.t()}
          | {:put_user, map()}
          | {:put_metadata, map()}

  @doc """
  Returns the supervision children required to run the configured cache adapter.
  """
  @spec child_specs(SlackBot.Config.t()) :: [Supervisor.child_spec()]
  def child_specs(%SlackBot.Config{} = config) do
    {adapter, opts} = adapter_from_config(config)
    assert_behaviour!(adapter)
    adapter.child_specs(config, opts)
  end

  @doc """
  Lists the channel IDs currently cached for the bot instance.
  """
  @spec channels(SlackBot.Config.t() | GenServer.server()) :: [String.t()]
  def channels(config_or_name) do
    {config, adapter, opts} = resolve(config_or_name)
    adapter.channels(config, opts)
  end

  @doc """
  Returns a map of user_id => user_payload for cached users.
  """
  @spec users(SlackBot.Config.t() | GenServer.server()) :: map()
  def users(config_or_name) do
    {config, adapter, opts} = resolve(config_or_name)
    adapter.users(config, opts)
  end

  @doc """
  Returns the cached metadata map merged via `put_metadata/2`.
  """
  @spec metadata(SlackBot.Config.t() | GenServer.server()) :: map()
  def metadata(config_or_name) do
    {config, adapter, opts} = resolve(config_or_name)
    adapter.metadata(config, opts)
  end

  @doc """
  Marks the bot as having joined the given `channel`.
  """
  @spec join_channel(SlackBot.Config.t(), String.t()) :: :ok
  def join_channel(config, channel) do
    mutate(config, {:join_channel, channel})
  end

  @doc """
  Marks the bot as having left the given `channel`.
  """
  @spec leave_channel(SlackBot.Config.t(), String.t()) :: :ok
  def leave_channel(config, channel) do
    mutate(config, {:leave_channel, channel})
  end

  @doc """
  Stores or updates a Slack user payload.
  """
  @spec put_user(SlackBot.Config.t(), map()) :: :ok
  def put_user(config, user) do
    mutate(config, {:put_user, user})
  end

  @doc """
  Merges arbitrary metadata (team info, workspace settings, etc.) into the cache.

  Use `metadata/1` to read the merged map back.
  """
  @spec put_metadata(SlackBot.Config.t(), map()) :: :ok
  def put_metadata(config, metadata) when is_map(metadata) do
    mutate(config, {:put_metadata, metadata})
  end

  defp mutate(%SlackBot.Config{} = config, op) do
    {adapter, opts} = adapter_from_config(config)
    adapter.mutate(config, opts, op)
  end

  defp resolve(%SlackBot.Config{} = config) do
    {adapter, opts} = adapter_from_config(config)
    {config, adapter, opts}
  end

  defp resolve(name) do
    config = SlackBot.config(name)
    resolve(config)
  end

  defp adapter_from_config(%SlackBot.Config{cache: {:adapter, module, opts}}), do: {module, opts}
  defp adapter_from_config(%SlackBot.Config{cache: {:ets, opts}}), do: {ETS, opts}
  defp adapter_from_config(%SlackBot.Config{}), do: {ETS, []}

  defp assert_behaviour!(module) when is_atom(module) do
    behaviours =
      if Code.ensure_loaded?(module) do
        module.module_info(:attributes)
        |> Keyword.get(:behaviour, [])
      else
        []
      end

    unless Adapter in behaviours do
      raise ArgumentError,
            "#{inspect(module)} must implement SlackBot.Cache.Adapter to be used as a cache backend"
    end
  end
end
