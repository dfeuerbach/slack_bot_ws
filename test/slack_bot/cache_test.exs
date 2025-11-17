defmodule SlackBot.CacheTest do
  use ExUnit.Case, async: true

  alias SlackBot.Cache

  setup do
    config =
      SlackBot.Config.build!(
        app_token: "xapp-cache",
        bot_token: "xoxb-cache",
        module: SlackBot.TestHandler,
        instance_name: CacheTest.Instance
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
  end
end
