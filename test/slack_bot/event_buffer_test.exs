defmodule SlackBot.EventBufferTest do
  use ExUnit.Case, async: true

  alias SlackBot.EventBuffer

  setup do
    config =
      SlackBot.Config.build!(
        app_token: "xapp-buffer",
        bot_token: "xoxb-buffer",
        module: SlackBot.TestHandler,
        instance_name: EventBufferTest.Instance,
        event_buffer: {:ets, [table: :event_buffer_test]}
      )

    child_spec = EventBuffer.child_spec(config)
    start_supervised!(child_spec)

    %{config: config}
  end

  test "records and detects envelopes", %{config: config} do
    refute EventBuffer.seen?(config, "E1")
    EventBuffer.record(config, "E1", %{payload: "value"})
    assert EventBuffer.seen?(config, "E1")

    EventBuffer.delete(config, "E1")
    refute EventBuffer.seen?(config, "E1")
  end

  test "returns pending payloads", %{config: config} do
    EventBuffer.record(config, "E2", %{payload: 1})
    EventBuffer.record(config, "E3", %{payload: 2})

    pending = EventBuffer.pending(config)
    assert Enum.count(pending) == 2
  end
end
