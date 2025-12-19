defmodule SlackBot.EventBufferTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SlackBot.EventBuffer
  alias SlackBot.EventBuffer.Adapter
  alias SlackBot.EventBuffer.Adapters.Redis

  defmodule CustomAdapter do
    @moduledoc false
    @behaviour Adapter

    def init(_opts) do
      {:ok, %{entries: %{}}}
    end

    def record(state, key, payload) do
      status =
        if Map.has_key?(state.entries, key) do
          :duplicate
        else
          :ok
        end

      {status, %{state | entries: Map.put(state.entries, key, payload)}}
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

  defmodule RedisErrorRedix do
    @moduledoc false
    def start_link(_opts), do: {:ok, self()}
    def command(_conn, _command), do: {:error, :redis_down}
    def pipeline(_conn, _commands), do: {:error, :redis_down}
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

  test "records envelopes once and flags duplicates", %{config: config} do
    assert :ok = EventBuffer.record(config, "E1", %{payload: "value"})
    assert :duplicate = EventBuffer.record(config, "E1", %{payload: "value"})
    assert EventBuffer.seen?(config, "E1")

    assert :ok = EventBuffer.delete(config, "E1")
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

    assert :ok = EventBuffer.record(config, "E5", %{payload: :ok})
    assert :duplicate = EventBuffer.record(config, "E5", %{payload: :ok})
    assert [%{payload: :ok}] = EventBuffer.pending(config)
  end

  test "redis adapter degrades gracefully on Redis errors" do
    capture_log(fn ->
      opts = [instance_name: EventBufferTest.RedisInstance, redix: RedisErrorRedix, ttl_ms: 1_000]

      assert {:ok, state} = Redis.init(opts)

      # record/3 should still return {:ok, state} even when Redis fails
      assert {:ok, _} = Redis.record(state, "E1", %{payload: :ok})

      # delete/2 should return {:ok, state} on error
      assert {:ok, _} = Redis.delete(state, "E1")

      # seen?/2 should treat errors as "not seen"
      assert {false, _} = Redis.seen?(state, "E1")

      # pending/1 should return an empty list on errors
      assert {[], _} = Redis.pending(state)
    end)
  end
end
