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
          | {:put_user, map(), non_neg_integer()}
          | {:drop_user, String.t()}
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
    ttl_ms = user_cache_opts(config).ttl_ms
    expires_at = now_ms() + ttl_ms
    mutate(config, {:put_user, user, expires_at})
  end

  @doc """
  Merges arbitrary metadata (team info, workspace settings, etc.) into the cache.

  Use `metadata/1` to read the merged map back.
  """
  @spec put_metadata(SlackBot.Config.t(), map()) :: :ok
  def put_metadata(config, metadata) when is_map(metadata) do
    mutate(config, {:put_metadata, metadata})
  end

  @doc """
  Fetches a cached user by Slack user ID.

  Returns `nil` when the user is not present in the cache.
  """
  @spec get_user(SlackBot.Config.t() | GenServer.server(), String.t()) :: map() | nil
  def get_user(config_or_name, user_id) when is_binary(user_id) do
    config_or_name
    |> users()
    |> Map.get(user_id)
  end

  @doc """
  Finds a cached user by secondary attributes.

  Supported matchers:

    * `{:email, email}` – matches against `user["profile"]["email"]` (case-insensitive).
    * `{:name, name}` – matches against `user["name"]` or `user["profile"]["display_name"]`
      (case-insensitive).

  Returns the first matching user map or `nil` when no user matches.
  """
  @spec find_user(
          SlackBot.Config.t() | GenServer.server(),
          {:email, String.t()} | {:name, String.t()}
        ) ::
          map() | nil
  def find_user(config_or_name, {:email, email}) when is_binary(email) do
    email_downcase = String.downcase(email)

    config_or_name
    |> users()
    |> Enum.find_value(fn
      {_id, %{"profile" => %{"email" => user_email}} = user} ->
        if is_binary(user_email) and String.downcase(user_email) == email_downcase do
          user
        else
          nil
        end

      _ ->
        nil
    end)
  end

  def find_user(config_or_name, {:name, name}) when is_binary(name) do
    name_downcase = String.downcase(name)

    config_or_name
    |> users()
    |> Enum.find_value(fn
      {_id, user} when is_map(user) ->
        cond do
          is_binary(user["name"]) and
              String.downcase(user["name"]) == name_downcase ->
            user

          match?(%{"profile" => %{"display_name" => _}}, user) and
            is_binary(get_in(user, ["profile", "display_name"])) and
              String.downcase(get_in(user, ["profile", "display_name"])) == name_downcase ->
            user

          true ->
            nil
        end

      _ ->
        nil
    end)
  end

  @doc """
  Fetches a user, refreshing the cache on demand when the entry is missing or stale.

  Returns `{:ok, user}` on success or `{:error, reason}` when the Slack API lookup fails.
  """
  @spec fetch_user(SlackBot.Config.t() | GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fetch_user(config_or_name, user_id, _opts \\ [])

  def fetch_user(_config_or_name, user_id, _opts) when not is_binary(user_id) do
    {:error, {:invalid_user_id, user_id}}
  end

  def fetch_user(config_or_name, user_id, _opts) do
    {config, adapter, adapter_opts} = resolve(config_or_name)
    ttl_ms = user_cache_opts(config).ttl_ms
    now = now_ms()

    case adapter.user_entry(config, adapter_opts, user_id) do
      {:ok, %{data: user, expires_at: expires_at}} when expires_at > now ->
        {:ok, user}

      {:ok, _stale} ->
        mutate(config, {:drop_user, user_id})
        fetch_and_cache_user(config, user_id, ttl_ms)

      :not_found ->
        fetch_and_cache_user(config, user_id, ttl_ms)
    end
  end

  @doc """
  Fetches a cached channel by Slack channel ID.

  This helper looks in the metadata map under the `\"channels_by_id\"` key, which is
  maintained by the background cache sync worker when enabled.
  """
  @spec get_channel(SlackBot.Config.t() | GenServer.server(), String.t()) :: map() | nil
  def get_channel(config_or_name, channel_id) when is_binary(channel_id) do
    config_or_name
    |> metadata()
    |> Map.get("channels_by_id", %{})
    |> Map.get(channel_id)
  end

  @doc """
  Finds a cached channel by human-readable name.

  The lookup is case-insensitive and accepts both bare names (`\"general\"`) and
  names prefixed with `\"#\"` (`\"#general\"`).

  Returns the first matching channel map or `nil` when no channel matches.
  """
  @spec find_channel(SlackBot.Config.t() | GenServer.server(), {:name, String.t()}) :: map() | nil
  def find_channel(config_or_name, {:name, name}) when is_binary(name) do
    target =
      name
      |> String.trim_leading("#")
      |> String.downcase()

    config_or_name
    |> metadata()
    |> Map.get("channels_by_id", %{})
    |> Enum.find_value(fn
      {_id, channel} when is_map(channel) ->
        name = channel["name"] || channel["name_normalized"]

        if is_binary(name) and String.downcase(name) == target do
          channel
        else
          nil
        end

      _ ->
        nil
    end)
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

  defp fetch_and_cache_user(config, user_id, ttl_ms) do
    case SlackBot.push(config, {"users.info", %{"user" => user_id}}) do
      {:ok, %{"user" => user}} ->
        expires_at = now_ms() + ttl_ms
        mutate(config, {:put_user, user, expires_at})
        {:ok, user}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp user_cache_opts(%SlackBot.Config{user_cache: opts}), do: opts

  defp now_ms, do: System.monotonic_time(:millisecond)
end
