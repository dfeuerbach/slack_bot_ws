defmodule SlackBot.LookupHelpersTest do
  use ExUnit.Case, async: true

  alias SlackBot.Cache

  defmodule HTTPStub do
    def apps_connections_open(_config), do: {:ok, "wss://lookup.test/socket"}

    def post(_config, _method, _body), do: {:error, :stubbed}
  end

  defmodule LookupBot do
    use SlackBot
  end

  setup do
    config =
      SlackBot.Config.build!(
        app_token: "xapp-lookup",
        bot_token: "xoxb-lookup",
        module: SlackBot.TestHandler,
        instance_name: __MODULE__,
        rate_limiter: :none,
        http_client: __MODULE__.HTTPStub
      )

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    Cache.put_user(config, %{
      "id" => "U1",
      "name" => "alice",
      "profile" => %{"email" => "alice@example.com", "display_name" => "Alice"}
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

    %{config: config}
  end

  test "find_user delegates to cache", %{config: config} do
    assert %{"id" => "U1"} = SlackBot.find_user(config, {:id, "U1"})
    assert %{"id" => "U1"} = SlackBot.find_user(config, {:email, "ALICE@example.com"})
    assert %{"id" => "U2"} = SlackBot.find_user(config, {:name, "bobby"})
    assert nil == SlackBot.find_user(config, {:name, "unknown"})
  end

  test "find_users batches lookups and can include misses", %{config: config} do
    matchers = [{:name, "alice"}, {:name, "missing"}]

    assert %{{:name, "alice"} => %{"id" => "U1"}} =
             SlackBot.find_users(config, matchers)

    assert %{
             {:name, "alice"} => %{"id" => "U1"},
             {:name, "missing"} => nil
           } = SlackBot.find_users(config, matchers, include_missing?: true)
  end

  test "find_channel supports id and name matchers", %{config: config} do
    assert %{"id" => "C1"} = SlackBot.find_channel(config, {:id, "C1"})
    assert %{"id" => "C1"} = SlackBot.find_channel(config, {:name, "#GENERAL"})
    assert %{"id" => "C2"} = SlackBot.find_channel(config, {:name, "random"})
  end

  test "find_channels batches lookups", %{config: config} do
    matchers = [{:name, "general"}, {:name, "unknown"}]

    assert %{{:name, "general"} => %{"id" => "C1"}} =
             SlackBot.find_channels(config, matchers)

    assert %{
             {:name, "general"} => %{"id" => "C1"},
             {:name, "unknown"} => nil
           } = SlackBot.find_channels(config, matchers, include_missing?: true)
  end

  test "macro injects lookup shortcuts" do
    assert function_exported?(LookupBot, :find_user, 1)
    assert function_exported?(LookupBot, :find_users, 2)
    assert function_exported?(LookupBot, :find_channel, 1)
    assert function_exported?(LookupBot, :find_channels, 2)
  end
end
