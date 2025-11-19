defmodule SlackBot.EventBufferTest do
  use ExUnit.Case, async: true

  alias SlackBot.EventBuffer

  defmodule CustomAdapter do
    @behaviour SlackBot.EventBuffer.Adapter

    def init(_opts) do
      {:ok, %{entries: %{}}}
    end

    def record(state, key, payload) do
      {:ok, %{state | entries: Map.put(state.entries, key, payload)}}
    end

    def delete(state, key) do
      {:ok, %{state | entries: Map.delete(state.entries, key)}}
    end

    def seen?(state, key) do
      {Map.has_key?(state.entries, key), state}
    end

    def pending(state) do
      {Map.values(state.entries), state}
    end
  end

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

  test "supports custom adapters" do
    config =
      SlackBot.Config.build!(
        app_token: "xapp-buffer",
        bot_token: "xoxb-buffer",
        module: SlackBot.TestHandler,
        instance_name: EventBufferTest.CustomInstance,
        event_buffer: {:adapter, __MODULE__.CustomAdapter, []}
      )

    start_supervised!(EventBuffer.child_spec(config))

    refute EventBuffer.seen?(config, "E5")
    EventBuffer.record(config, "E5", %{payload: :ok})
    assert EventBuffer.seen?(config, "E5")
    assert [%{payload: :ok}] = EventBuffer.pending(config)
  end
end
