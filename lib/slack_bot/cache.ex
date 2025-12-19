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

  @doc false
  @spec child_specs(SlackBot.Config.t()) :: [Supervisor.child_spec()]
  def child_specs(%SlackBot.Config{} = config) do
    {adapter, opts} = adapter_from_config(config)
    assert_behaviour!(adapter)
    adapter.child_specs(config, opts)
  end

  @doc false
  @spec channels(SlackBot.Config.t() | GenServer.server()) :: [String.t()]
  def channels(config_or_name) do
    {config, adapter, opts} = resolve(config_or_name)
    adapter.channels(config, opts)
  end

  @doc false
  @spec users(SlackBot.Config.t() | GenServer.server()) :: map()
  def users(config_or_name) do
    {config, adapter, opts} = resolve(config_or_name)
    adapter.users(config, opts)
  end

  @doc false
  @spec metadata(SlackBot.Config.t() | GenServer.server()) :: map()
  def metadata(config_or_name) do
    {config, adapter, opts} = resolve(config_or_name)
    adapter.metadata(config, opts)
  end

  @doc false
  @spec join_channel(SlackBot.Config.t(), String.t()) :: :ok
  def join_channel(config, channel) do
    mutate(config, {:join_channel, channel})
  end

  @doc false
  @spec leave_channel(SlackBot.Config.t(), String.t()) :: :ok
  def leave_channel(config, channel) do
    mutate(config, {:leave_channel, channel})
  end

  @doc false
  @spec put_user(SlackBot.Config.t(), map()) :: :ok
  def put_user(config, user) do
    ttl_ms = user_cache_opts(config).ttl_ms
    expires_at = now_ms() + ttl_ms
    mutate(config, {:put_user, user, expires_at})
  end

  @doc false
  @spec put_metadata(SlackBot.Config.t(), map()) :: :ok
  def put_metadata(config, metadata) when is_map(metadata) do
    mutate(config, {:put_metadata, metadata})
  end

  @doc false
  @spec get_user(SlackBot.Config.t() | GenServer.server(), String.t()) :: map() | nil
  def get_user(config_or_name, user_id) when is_binary(user_id) do
    config_or_name
    |> users()
    |> Map.get(user_id)
  end

  @doc false
  @spec find_user(
          SlackBot.Config.t() | GenServer.server(),
          {:id, String.t()} | {:email, String.t()} | {:name, String.t()}
        ) ::
          map() | nil
  def find_user(config_or_name, {:id, user_id}) when is_binary(user_id) do
    get_user(config_or_name, user_id) ||
      config_or_name
      |> ensure_config()
      |> fetch_user_by_id(user_id)
  end

  def find_user(config_or_name, {:email, email}) when is_binary(email) do
    find_user_by_email_in_cache(config_or_name, email) ||
      config_or_name
      |> ensure_config()
      |> fetch_user_by_email(email)
  end

  def find_user(config_or_name, {:name, name}) when is_binary(name) do
    find_user_by_name_in_cache(config_or_name, name) ||
      config_or_name
      |> ensure_config()
      |> fetch_user_by_name(name)
  end

  @doc false
  @spec get_channel(SlackBot.Config.t() | GenServer.server(), String.t()) :: map() | nil
  def get_channel(config_or_name, channel_id) when is_binary(channel_id) do
    config_or_name
    |> metadata()
    |> Map.get("channels_by_id", %{})
    |> Map.get(channel_id)
  end

  @doc false
  @spec find_channel(
          SlackBot.Config.t() | GenServer.server(),
          {:id, String.t()} | {:name, String.t()}
        ) :: map() | nil
  def find_channel(config_or_name, {:id, channel_id}) when is_binary(channel_id) do
    get_channel(config_or_name, channel_id) ||
      config_or_name
      |> ensure_config()
      |> fetch_channel_by_id(channel_id)
  end

  def find_channel(config_or_name, {:name, name}) when is_binary(name) do
    target = normalize_channel_name(name)

    find_channel_by_name_in_cache(config_or_name, target) ||
      config_or_name
      |> ensure_config()
      |> fetch_channel_by_name(target)
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

  defp ensure_config(%SlackBot.Config{} = config), do: config
  defp ensure_config(name), do: SlackBot.config(name)

  defp find_user_by_email_in_cache(config_or_name, email) do
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

  defp find_user_by_name_in_cache(config_or_name, name) do
    name_downcase = String.downcase(name)

    config_or_name
    |> users()
    |> Enum.find_value(fn
      {_id, user} when is_map(user) ->
        user_name_matches?(user, name_downcase)

      _ ->
        nil
    end)
  end

  defp fetch_user_by_id(%SlackBot.Config{} = config, user_id) do
    case SlackBot.push(config, {"users.info", %{"user" => user_id}}) do
      {:ok, %{"user" => user}} -> cache_user(config, user)
      _ -> nil
    end
  end

  defp fetch_user_by_email(%SlackBot.Config{} = config, email) do
    case SlackBot.push(config, {"users.lookupByEmail", %{"email" => email}}) do
      {:ok, %{"user" => user}} -> cache_user(config, user)
      _ -> nil
    end
  end

  defp fetch_user_by_name(%SlackBot.Config{} = config, name) do
    name_downcase = String.downcase(name)
    fetch_user_list_page(config, name_downcase, nil)
  end

  defp fetch_user_list_page(config, name_downcase, cursor) do
    %{"limit" => 200}
    |> maybe_put_cursor(cursor)
    |> fetch_user_list(config)
    |> handle_user_list_response(config, name_downcase)
  end

  defp fetch_user_list(body, config), do: SlackBot.push(config, {"users.list", body})

  defp handle_user_list_response({:ok, %{"members" => members} = resp}, config, name_downcase) do
    Enum.each(members, &cache_user(config, &1))

    members
    |> Enum.find(&user_name_matches?(&1, name_downcase))
    |> maybe_continue_user_search(resp, config, name_downcase)
  end

  defp handle_user_list_response(_response, _config, _name), do: nil

  defp maybe_continue_user_search(nil, resp, config, name_downcase) do
    resp
    |> response_next_cursor()
    |> fetch_next_user_page(config, name_downcase)
  end

  defp maybe_continue_user_search(user, _resp, _config, _name), do: user

  defp fetch_next_user_page("", _config, _name), do: nil
  defp fetch_next_user_page(nil, _config, _name), do: nil

  defp fetch_next_user_page(cursor, config, name_downcase) do
    fetch_user_list_page(config, name_downcase, cursor)
  end

  defp user_name_matches?(user, target) do
    cond do
      is_binary(user["name"]) and String.downcase(user["name"]) == target ->
        user

      match?(%{"profile" => %{"display_name" => _}}, user) and
        is_binary(get_in(user, ["profile", "display_name"])) and
          String.downcase(get_in(user, ["profile", "display_name"])) == target ->
        user

      true ->
        nil
    end
  end

  defp cache_user(%SlackBot.Config{} = config, %{"id" => user_id} = user)
       when is_binary(user_id) do
    ttl_ms = user_cache_opts(config).ttl_ms
    expires_at = now_ms() + ttl_ms
    mutate(config, {:put_user, user, expires_at})
    user
  end

  defp cache_user(_config, _user), do: nil

  defp find_channel_by_name_in_cache(config_or_name, target) do
    config_or_name
    |> metadata()
    |> Map.get("channels_by_id", %{})
    |> Enum.find_value(fn
      {_id, channel} when is_map(channel) ->
        if channel_name_matches?(channel, target), do: channel, else: nil

      _ ->
        nil
    end)
  end

  defp fetch_channel_by_id(%SlackBot.Config{} = config, channel_id) do
    case SlackBot.push(config, {"conversations.info", %{"channel" => channel_id}}) do
      {:ok, %{"channel" => channel}} -> cache_channel(config, channel)
      _ -> nil
    end
  end

  defp fetch_channel_by_name(%SlackBot.Config{} = config, target) do
    config
    |> resolve_bot_user_id()
    |> fetch_channel_by_name(config, target)
  end

  defp fetch_channel_by_name({:ok, bot_user_id}, %SlackBot.Config{} = config, target)
       when is_binary(bot_user_id) do
    do_fetch_channel_by_name(config, bot_user_id, target, nil)
  end

  defp fetch_channel_by_name(_error, _config, _target), do: nil

  defp do_fetch_channel_by_name(config, bot_user_id, target, cursor) do
    config.cache_sync.users_conversations_opts
    |> Map.put("user", bot_user_id)
    |> maybe_put_cursor(cursor)
    |> fetch_conversations(config)
    |> handle_channel_page(config, bot_user_id, target)
  end

  defp handle_channel_page({:ok, %{"channels" => channels} = resp}, config, bot_user_id, target) do
    Enum.each(channels, &cache_channel(config, &1))

    channels
    |> Enum.find(&channel_name_matches?(&1, target))
    |> maybe_continue_channel_search(resp, config, bot_user_id, target)
  end

  defp handle_channel_page(_response, _config, _bot_user_id, _target), do: nil

  defp maybe_continue_channel_search(nil, resp, config, bot_user_id, target) do
    resp
    |> response_next_cursor()
    |> fetch_next_channel_page(config, bot_user_id, target)
  end

  defp maybe_continue_channel_search(channel, _resp, _config, _bot_user_id, _target), do: channel

  defp fetch_next_channel_page("", _config, _bot_user_id, _target), do: nil
  defp fetch_next_channel_page(nil, _config, _bot_user_id, _target), do: nil

  defp fetch_next_channel_page(cursor, config, bot_user_id, target) do
    do_fetch_channel_by_name(config, bot_user_id, target, cursor)
  end

  defp fetch_conversations(body, config), do: SlackBot.push(config, {"users.conversations", body})

  defp cache_channel(%SlackBot.Config{} = config, %{"id" => channel_id} = channel)
       when is_binary(channel_id) do
    join_channel(config, channel_id)
    put_metadata(config, %{"channels_by_id" => %{channel_id => channel}})
    channel
  end

  defp cache_channel(_config, _channel), do: nil

  defp resolve_bot_user_id(%SlackBot.Config{assigns: %{bot_user_id: id}}) when is_binary(id),
    do: {:ok, id}

  defp resolve_bot_user_id(%SlackBot.Config{} = config) do
    case SlackBot.push(config, {"auth.test", %{}}) do
      {:ok, %{"user_id" => user_id}} when is_binary(user_id) -> {:ok, user_id}
      _ -> {:error, :bot_identity_unavailable}
    end
  end

  defp normalize_channel_name(name) do
    name
    |> String.trim_leading("#")
    |> String.downcase()
  end

  defp channel_name_matches?(channel, target) do
    candidate = channel["name"] || channel["name_normalized"]
    is_binary(candidate) and String.downcase(candidate) == target
  end

  defp response_next_cursor(resp) do
    resp
    |> Map.get("response_metadata", %{})
    |> Map.get("next_cursor", "")
  end

  defp maybe_put_cursor(body, nil), do: body

  defp maybe_put_cursor(body, cursor) when is_binary(cursor) and cursor != "" do
    Map.put(body, "cursor", cursor)
  end

  defp maybe_put_cursor(body, _), do: body

  defp user_cache_opts(%SlackBot.Config{user_cache: opts}), do: opts

  defp now_ms, do: System.monotonic_time(:millisecond)
end
