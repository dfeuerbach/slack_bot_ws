defmodule SlackBot.CacheTest do
  use ExUnit.Case, async: true

  alias SlackBot.Cache

  defmodule CustomAdapter do
    @behaviour SlackBot.Cache.Adapter

    def child_specs(%SlackBot.Config{instance_name: instance}, _opts) do
      name = table_name(instance)

      [
        %{
          id: name,
          start:
            {Agent, :start_link,
             [
               fn -> %{channels: MapSet.new(), users: %{}, metadata: %{}} end,
               [name: name]
             ]}
        }
      ]
    end

    def channels(%SlackBot.Config{instance_name: instance}, _opts) do
      Agent.get(table_name(instance), fn %{channels: channels} ->
        channels |> MapSet.to_list() |> Enum.sort()
      end)
    end

    def users(%SlackBot.Config{instance_name: instance}, _opts) do
      Agent.get(table_name(instance), fn %{users: users} ->
        Map.new(users, fn {id, entry} -> {id, entry.data} end)
      end)
    end

    def metadata(%SlackBot.Config{instance_name: instance}, _opts) do
      Agent.get(table_name(instance), & &1.metadata)
    end

    def mutate(%SlackBot.Config{instance_name: instance}, _opts, op) do
      Agent.update(table_name(instance), &apply_op(&1, op))
    end

    def user_entry(%SlackBot.Config{instance_name: instance}, _opts, user_id) do
      Agent.get(table_name(instance), fn %{users: users} ->
        case Map.fetch(users, user_id) do
          {:ok, entry} -> {:ok, entry}
          :error -> :not_found
        end
      end)
    end

    defp apply_op(state, {:join_channel, channel}) do
      update_in(state.channels, &MapSet.put(&1, channel))
    end

    defp apply_op(state, {:leave_channel, channel}) do
      update_in(state.channels, &MapSet.delete(&1, channel))
    end

    defp apply_op(state, {:put_user, %{"id" => id} = user, expires_at}) do
      entry = %{data: user, expires_at: expires_at}
      update_in(state.users, &Map.put(&1, id, entry))
    end

    defp apply_op(state, {:put_user, %{"id" => id} = user}) do
      entry = %{data: user, expires_at: :infinity}
      update_in(state.users, &Map.put(&1, id, entry))
    end

    defp apply_op(state, {:drop_user, user_id}) do
      update_in(state.users, &Map.delete(&1, user_id))
    end

    defp apply_op(state, {:put_metadata, metadata}) do
      update_in(state.metadata, &Map.merge(&1, metadata))
    end

    defp apply_op(state, _), do: state

    defp table_name(instance) do
      Module.concat(instance, CustomCacheAgent)
    end
  end

  defmodule FetchHTTP do
    def apps_connections_open(_config), do: {:ok, "wss://test.example/socket"}

    def post(_config, "users.info", %{"user" => user_id}) do
      bump(:users_info_calls)
      {:ok, %{"user" => user_payload(user_id)}}
    end

    def post(_config, "users.lookupByEmail", %{"email" => email}) do
      bump(:users_lookup_calls)
      {:ok, %{"user" => user_payload("lookup-#{email}")}}
    end

    def post(_config, "users.list", body) do
      bump(:users_list_calls)

      members =
        [
          user_payload("U-LIST-1", %{
            "name" => "alice",
            "profile" => %{"display_name" => "Alice"}
          }),
          user_payload("U-LIST-2", %{
            "name" => "bob",
            "profile" => %{"display_name" => "Bobby"}
          })
        ]

      response =
        if Map.get(body, "cursor") == "end" do
          %{"members" => [], "response_metadata" => %{"next_cursor" => ""}}
        else
          %{"members" => members, "response_metadata" => %{"next_cursor" => ""}}
        end

      {:ok, response}
    end

    def post(_config, "conversations.info", %{"channel" => channel_id}) do
      bump(:conversations_info_calls)

      {:ok,
       %{
         "channel" => %{
           "id" => channel_id,
           "name" => "chan-#{channel_id}"
         }
       }}
    end

    def post(_config, "users.conversations", body) do
      bump(:users_conversations_calls)

      channels =
        [
          %{"id" => "C-ENG", "name" => "eng"},
          %{"id" => "C-SALES", "name_normalized" => "sales"}
        ]

      response =
        if Map.get(body, "cursor") == "end" do
          %{"channels" => [], "response_metadata" => %{"next_cursor" => ""}}
        else
          %{"channels" => channels, "response_metadata" => %{"next_cursor" => ""}}
        end

      {:ok, response}
    end

    def post(_config, "auth.test", _body) do
      {:ok, %{"user_id" => "U-BOT"}}
    end

    def post(_config, _method, body), do: {:ok, body}

    defp bump(key) do
      count = Process.get(key, 0)
      Process.put(key, count + 1)
    end

    defp user_payload(id, extras \\ %{}) do
      Map.merge(
        %{"id" => id, "name" => "user-#{id}", "profile" => %{"email" => "#{id}@example.com"}},
        extras
      )
    end
  end

  setup do
    config =
      SlackBot.Config.build!(
        app_token: "xapp-cache",
        bot_token: "xoxb-cache",
        module: SlackBot.TestHandler,
        instance_name: CacheTest.Instance,
        rate_limiter: :none
      )

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    %{config: config}
  end

  test "tracks channel joins and parts", %{config: config} do
    Cache.join_channel(config, "C123")
    assert Cache.channels(config) == ["C123"]

    Cache.leave_channel(config, "C123")
    assert Cache.channels(config) == []
  end

  test "stores users and metadata", %{config: config} do
    Cache.put_user(config, %{"id" => "U1", "name" => "Test"})
    Cache.put_metadata(config, %{"team_id" => "T1"})

    assert %{"U1" => %{"id" => "U1"}} = Cache.users(config)
    assert %{"team_id" => "T1"} = Cache.metadata(config)
  end

  test "lookup helpers fetch users and channels by id and attributes", %{config: config} do
    Cache.put_user(config, %{
      "id" => "U1",
      "name" => "alice",
      "profile" => %{"email" => "alice@example.com", "display_name" => "Alice A."}
    })

    Cache.put_user(config, %{
      "id" => "U2",
      "name" => "bob",
      "profile" => %{"email" => "bob@example.com", "display_name" => "Bobby"}
    })

    Cache.put_metadata(config, %{
      "channels_by_id" => %{
        "C1" => %{"id" => "C1", "name" => "general"},
        "C2" => %{"id" => "C2", "name_normalized" => "random"}
      }
    })

    assert %{"id" => "U1"} = Cache.get_user(config, "U1")
    assert nil == Cache.get_user(config, "UX")

    assert %{"profile" => %{"email" => "alice@example.com"}} =
             Cache.find_user(config, {:email, "ALICE@example.com"})

    assert %{"name" => "bob"} = Cache.find_user(config, {:name, "bob"})

    assert %{"profile" => %{"display_name" => "Bobby"}} =
             Cache.find_user(config, {:name, "bobby"})

    assert %{"id" => "C1"} = Cache.get_channel(config, "C1")
    assert nil == Cache.get_channel(config, "CX")

    assert %{"id" => "C1"} = Cache.find_channel(config, {:name, "#GENERAL"})
    assert %{"id" => "C2"} = Cache.find_channel(config, {:name, "random"})
  end

  test "supports custom adapters" do
    config =
      SlackBot.Config.build!(
        app_token: "xapp-cache",
        bot_token: "xoxb-cache",
        module: SlackBot.TestHandler,
        instance_name: CustomAdapter.Instance,
        cache: {:adapter, __MODULE__.CustomAdapter, []}
      )

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    Cache.join_channel(config, "C900")
    Cache.put_user(config, %{"id" => "UA", "email" => "a@example.com"})

    assert Cache.channels(config) == ["C900"]
    assert %{"UA" => %{"email" => "a@example.com"}} = Cache.users(config)
  end

  test "find_user is read-through for ids, emails, and names" do
    Process.put(:users_info_calls, 0)
    Process.put(:users_lookup_calls, 0)
    Process.put(:users_list_calls, 0)

    config =
      SlackBot.Config.build!(
        app_token: "xapp-cache",
        bot_token: "xoxb-cache",
        module: SlackBot.TestHandler,
        instance_name: CacheTest.ReadThroughUsers,
        rate_limiter: :none,
        http_client: __MODULE__.FetchHTTP,
        user_cache: %{ttl_ms: 20, cleanup_interval_ms: 10}
      )

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    assert %{"id" => "UF1"} = Cache.find_user(config, {:id, "UF1"})
    assert Process.get(:users_info_calls) == 1
    assert %{"id" => "UF1"} = Cache.find_user(config, {:id, "UF1"})
    assert Process.get(:users_info_calls) == 1

    assert %{"id" => "lookup-ops@example.com"} =
             Cache.find_user(config, {:email, "ops@example.com"})

    assert Process.get(:users_lookup_calls) == 1

    assert %{"id" => "U-LIST-2"} = Cache.find_user(config, {:name, "bobby"})
    assert Process.get(:users_list_calls) == 1
  end

  test "find_channel is read-through for ids and names" do
    Process.put(:conversations_info_calls, 0)
    Process.put(:users_conversations_calls, 0)

    config =
      SlackBot.Config.build!(
        app_token: "xapp-cache",
        bot_token: "xoxb-cache",
        module: SlackBot.TestHandler,
        instance_name: CacheTest.ReadThroughChannels,
        rate_limiter: :none,
        http_client: __MODULE__.FetchHTTP
      )

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    assert %{"id" => "C-42"} = Cache.find_channel(config, {:id, "C-42"})
    assert Process.get(:conversations_info_calls) == 1
    assert %{"id" => "C-42"} = Cache.find_channel(config, {:id, "C-42"})
    assert Process.get(:conversations_info_calls) == 1

    assert %{"id" => "C-SALES"} = Cache.find_channel(config, {:name, "#sales"})
    assert Process.get(:users_conversations_calls) == 1
  end

  test "janitor removes expired users" do
    config =
      SlackBot.Config.build!(
        app_token: "xapp-cache",
        bot_token: "xoxb-cache",
        module: SlackBot.TestHandler,
        instance_name: CacheTest.JanitorInstance,
        rate_limiter: :none,
        user_cache: %{ttl_ms: 10, cleanup_interval_ms: 10}
      )

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    Cache.put_user(config, %{"id" => "UJ1", "name" => "Jan"})
    assert Map.has_key?(Cache.users(config), "UJ1")

    Process.sleep(40)

    assert %{} = Cache.users(config)
  end
end
