defmodule SlackBot.RuntimeSupervisorTest do
  use ExUnit.Case, async: true

  defmodule Bot do
    def handle_event(_type, _payload, _ctx), do: :ok
  end

  test "Finch pools start before cache sync supervisor" do
    config_server =
      start_supervised!({SlackBot.ConfigServer,
        config: [app_token: "xapp-test", bot_token: "xoxb-test", module: Bot]
      })

    base_name = Bot
    runtime_name = Module.concat(base_name, :RuntimeSupervisor)

    {:ok, {_, child_specs}} =
      SlackBot.RuntimeSupervisor.init(
        runtime_name: runtime_name,
        base_name: base_name,
        config_server: config_server
      )

    child_ids = Enum.map(child_specs, & &1.id)

    ack_name = Module.concat(base_name, :AckFinch)
    api_name = Module.concat(base_name, :APIFinch)
    cache_sync_name = Module.concat(base_name, CacheSyncSupervisor)

    assert index(child_ids, ack_name) < index(child_ids, cache_sync_name)
    assert index(child_ids, api_name) < index(child_ids, cache_sync_name)
  end

  defp index(ids, child_id) do
    Enum.find_index(ids, &(&1 == child_id)) ||
      flunk("expected to find #{inspect(child_id)} in #{inspect(ids)}")
  end
end
