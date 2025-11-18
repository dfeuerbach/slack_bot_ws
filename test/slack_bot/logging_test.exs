defmodule SlackBot.LoggingTest do
  use ExUnit.Case, async: true

  alias SlackBot.Logging

  require Logger

  setup do
    Logger.metadata([])
    :ok
  end

  test "with_envelope attaches and clears metadata" do
    envelope = %{"envelope_id" => "E1"}
    payload = %{"event" => %{"type" => "message", "channel" => "C1", "user" => "U1"}}

    Logging.with_envelope(envelope, payload, fn ->
      meta = Logger.metadata()
      assert meta[:slack_envelope_id] == "E1"
      assert meta[:slack_event_type] == "message"
      assert meta[:slack_channel] == "C1"
      assert meta[:slack_user] == "U1"
    end)

    refute Logger.metadata()[:slack_envelope_id]
    refute Logger.metadata()[:slack_event_type]
  end

  test "metadata/3 merges extras and skips empty values" do
    payload = %{"type" => "app_mention", "channel" => "", "user" => nil}

    assert Logging.metadata(nil, payload, foo: :bar) == [
             slack_event_type: "app_mention",
             foo: :bar
           ]
  end
end
