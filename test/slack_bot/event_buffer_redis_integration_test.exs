defmodule SlackBot.EventBufferRedisIntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias SlackBot.EventBuffer

  setup do
    SlackBot.TestRedis.ensure!()

    config =
      SlackBot.Config.build!(
        app_token: "xapp-buffer",
        bot_token: "xoxb-buffer",
        module: SlackBot.TestHandler,
        instance_name: SlackBot.TestRedis.unique_instance("EventBufferRedis"),
        event_buffer:
          {:adapter, SlackBot.EventBuffer.Adapters.Redis,
           [
             redis: SlackBot.TestRedis.redis_start_opts(),
             namespace: "slackbot:event_buffer:test"
           ]}
      )

    start_supervised!(EventBuffer.child_spec(config))

    %{config: config}
  end

  test "records envelopes, dedupes, and lists pending payloads", %{config: config} do
    payload = %{payload: :live_redis}

    assert :ok = EventBuffer.record(config, "E-live", payload)
    assert :duplicate = EventBuffer.record(config, "E-live", payload)
    assert EventBuffer.seen?(config, "E-live")

    assert [^payload] = EventBuffer.pending(config)

    assert :ok = EventBuffer.delete(config, "E-live")
    refute EventBuffer.seen?(config, "E-live")
    assert [] = EventBuffer.pending(config)
  end
end
