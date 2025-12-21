defmodule SlackBot.EventBufferTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SlackBot.EventBuffer
  alias SlackBot.EventBuffer.Adapter

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

      assert {:ok, state} = SlackBot.EventBuffer.Adapters.Redis.init(opts)

      assert {:ok, _} = SlackBot.EventBuffer.Adapters.Redis.record(state, "E1", %{payload: :ok})
      assert {:ok, _} = SlackBot.EventBuffer.Adapters.Redis.delete(state, "E1")
      assert {false, _} = SlackBot.EventBuffer.Adapters.Redis.seen?(state, "E1")
      assert {[], _} = SlackBot.EventBuffer.Adapters.Redis.pending(state)
    end)
  end
end
