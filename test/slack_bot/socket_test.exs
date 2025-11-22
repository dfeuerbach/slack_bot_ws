defmodule SlackBot.SocketTest do
  use ExUnit.Case, async: true

  alias SlackBot.Socket

  test "classifies interactive shortcut payloads" do
    payload = %{"type" => "shortcut", "callback_id" => "demo"}
    assert {:interactive, "shortcut", ^payload} = Socket.classify_payload(payload)
  end

  for type <- ~w(message_action workflow_step_edit workflow_step_execute block_suggestion) do
    test "classifies #{type} interactive payloads" do
      payload = %{"type" => unquote(type), "callback_id" => "demo"}
      assert {:interactive, unquote(type), ^payload} = Socket.classify_payload(payload)
    end
  end

  test "classifies slash command payloads" do
    payload = %{"type" => "slash_commands", "command" => "/demo"}
    assert {:slash, ^payload} = Socket.classify_payload(payload)
  end

  test "classifies events" do
    payload = %{"event" => %{"type" => "reaction_added", "item" => %{}}}

    assert {:event, "reaction_added", %{"type" => "reaction_added"}} =
             Socket.classify_payload(payload)
  end
end
