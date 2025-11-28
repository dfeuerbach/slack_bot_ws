defmodule SlackBot.CacheSyncTest do
  use ExUnit.Case, async: true

  alias SlackBot.Cache
  alias SlackBot.Cache.Sync
  alias SlackBot.ConfigServer

  defmodule SyncHTTP do
    def apps_connections_open(_config), do: {:ok, "wss://test.example/socket"}

    def post(_config, "auth.test", _body) do
      {:ok, %{"ok" => true, "user_id" => "UBOT"}}
    end

    def post(_config, "users.list", body) do
      case Map.get(body, "cursor") do
        nil ->
          {:ok,
           %{
             "ok" => true,
             "members" => [
               %{
                 "id" => "U1",
                 "name" => "alice",
                 "profile" => %{"email" => "alice@example.com"}
               }
             ],
             "response_metadata" => %{"next_cursor" => "next"}
           }}

        "next" ->
          {:ok,
           %{
             "ok" => true,
             "members" => [
               %{
                 "id" => "U2",
                 "name" => "bob",
                 "profile" => %{"email" => "bob@example.com"}
               }
             ],
             "response_metadata" => %{"next_cursor" => ""}
           }}
      end
    end

    def post(_config, "users.conversations", body) do
      case Map.get(body, "cursor") do
        nil ->
          {:ok,
           %{
             "ok" => true,
             "channels" => [
               %{"id" => "C1", "name" => "general", "topic" => %{}, "purpose" => %{}}
             ],
             "response_metadata" => %{"next_cursor" => "next"}
           }}

        "next" ->
          {:ok,
           %{
             "ok" => true,
             "channels" => [
               %{"id" => "C3", "name" => "incidents", "topic" => %{}, "purpose" => %{}}
             ],
             "response_metadata" => %{"next_cursor" => ""}
           }}
      end
    end
  end

  defmodule PresenceHTTP do
    def apps_connections_open(_config), do: {:ok, "wss://test.example/socket"}

    def post(_config, "users.list", %{"presence" => true} = _body) do
      {:ok,
       %{
         "ok" => true,
         "members" => [
           %{
             "id" => "U3",
             "name" => "carol",
             "profile" => %{"email" => "carol@example.com"},
             "presence" => "active"
           }
         ],
         "response_metadata" => %{"next_cursor" => ""}
       }}
    end

    def post(config, method, body), do: SyncHTTP.post(config, method, body)
  end

  setup do
    Application.delete_env(:slack_bot_ws, SlackBot)

    handler_id = {:cache_sync_test_api, make_ref()}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:slackbot, :api, :request],
      fn _event, _measurements, metadata, _ ->
        send(parent, {:api_request, metadata.method})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  test "syncs users and channels into cache" do
    instance = __MODULE__.Instance

    config_opts = [
      app_token: "xapp-sync",
      bot_token: "xoxb-sync",
      module: SlackBot.TestHandler,
      http_client: SyncHTTP,
      instance_name: instance,
      assigns: %{bot_user_id: "UBOT"},
      cache_sync: [
        enabled: true,
        kinds: [:users, :channels],
        interval_ms: 50
      ]
    ]

    {:ok, _} = start_supervised({ConfigServer, name: :sync_config, config: config_opts})
    config = ConfigServer.config(:sync_config)

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    start_supervised!(SlackBot.RateLimiter.child_spec(config))

    base_name = Module.concat(__MODULE__, InstanceBase)

    {:ok, _pid} =
      start_supervised(
        {Sync, name: :sync_supervisor, config_server: :sync_config, base_name: base_name}
      )

    assert eventually(fn ->
             users = Cache.users(config)
             channels = Cache.channels(config) |> Enum.sort()
             metadata = Cache.metadata(config)

             not is_nil(users["U1"]) and
               not is_nil(users["U2"]) and
               channels == ["C1", "C3"] and
               Map.has_key?(metadata, "channels_by_id") and
               Map.has_key?(metadata["channels_by_id"], "C1") and
               Map.has_key?(metadata["channels_by_id"], "C3")
           end)

    assert_methods_seen(["users.list", "users.conversations"])
  end

  test "discovers bot identity via auth.test when not provided" do
    instance = __MODULE__.IdentityInstance

    config_opts = [
      app_token: "xapp-sync",
      bot_token: "xoxb-sync",
      module: SlackBot.TestHandler,
      http_client: SyncHTTP,
      instance_name: instance,
      cache_sync: [
        enabled: true,
        kinds: [:channels],
        interval_ms: 50
      ]
    ]

    {:ok, _} = start_supervised({ConfigServer, name: :identity_sync_config, config: config_opts})

    config = ConfigServer.config(:identity_sync_config)

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    start_supervised!(SlackBot.RateLimiter.child_spec(config))

    base_name = Module.concat(__MODULE__, IdentityBase)

    {:ok, _pid} =
      start_supervised(
        {Sync,
         name: :identity_sync_supervisor,
         config_server: :identity_sync_config,
         base_name: base_name}
      )

    assert eventually(fn ->
             Cache.channels(config) |> Enum.sort() == ["C1", "C3"]
           end)

    assert_methods_seen(["auth.test", "users.conversations"])
  end

  test "includes presence field when configured" do
    instance = __MODULE__.PresenceInstance

    config_opts = [
      app_token: "xapp-sync",
      bot_token: "xoxb-sync",
      module: SlackBot.TestHandler,
      http_client: PresenceHTTP,
      instance_name: instance,
      cache_sync: [
        enabled: true,
        kinds: [:users],
        interval_ms: 50,
        include_presence: true
      ]
    ]

    {:ok, _} = start_supervised({ConfigServer, name: :presence_config, config: config_opts})
    config = ConfigServer.config(:presence_config)

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    start_supervised!(SlackBot.RateLimiter.child_spec(config))

    base_name = Module.concat(__MODULE__, PresenceBase)

    {:ok, _pid} =
      start_supervised(
        {Sync,
         name: :presence_sync_supervisor, config_server: :presence_config, base_name: base_name}
      )

    assert eventually(fn ->
             case Cache.get_user(config, "U3") do
               %{"presence" => "active"} -> true
               _ -> false
             end
           end)

    assert_methods_seen(["users.list"])
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    case fun.() do
      true ->
        true

      false ->
        :timer.sleep(20)
        eventually(fun, attempts - 1)
    end
  end

  defp assert_methods_seen(expected_methods) do
    Process.sleep(10)

    methods =
      collect_methods([])
      |> Enum.reverse()

    Enum.each(expected_methods, fn method ->
      assert method in methods, "expected #{method} to be called; got #{inspect(methods)}"
    end)
  end

  defp collect_methods(acc) do
    receive do
      {:api_request, method} ->
        collect_methods([method | acc])
    after
      0 ->
        acc
    end
  end
end
