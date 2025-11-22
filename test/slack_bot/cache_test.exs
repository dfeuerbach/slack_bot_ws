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
      Agent.get(table_name(instance), & &1.users)
    end

    def metadata(%SlackBot.Config{instance_name: instance}, _opts) do
      Agent.get(table_name(instance), & &1.metadata)
    end

    def mutate(%SlackBot.Config{instance_name: instance}, _opts, op) do
      Agent.update(table_name(instance), &apply_op(&1, op))
    end

    defp apply_op(state, {:join_channel, channel}) do
      update_in(state.channels, &MapSet.put(&1, channel))
    end

    defp apply_op(state, {:leave_channel, channel}) do
      update_in(state.channels, &MapSet.delete(&1, channel))
    end

    defp apply_op(state, {:put_user, %{"id" => id} = user}) do
      update_in(state.users, &Map.put(&1, id, user))
    end

    defp apply_op(state, {:put_metadata, metadata}) do
      update_in(state.metadata, &Map.merge(&1, metadata))
    end

    defp apply_op(state, _), do: state

    defp table_name(instance) do
      Module.concat(instance, CustomCacheAgent)
    end
  end

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
    assert %{"team_id" => "T1"} = Cache.metadata(config)
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
end
