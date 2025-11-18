defmodule SlackBot.BlocksTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SlackBot.Blocks

  defp config(overrides \\ []) do
    base =
      Map.from_struct(%SlackBot.Config{
        app_token: "xapp",
        bot_token: "xoxb",
        module: __MODULE__,
        block_builder: :none,
        instance_name: :blocks_test
      })

    struct!(SlackBot.Config, Map.merge(base, Enum.into(overrides, %{})))
  end

  test "build/2 returns result when blockbox disabled" do
    assert [:ok] = Blocks.build(config(), fn -> [:ok] end)
  end

  test "blockbox?/1 reflects config" do
    refute Blocks.blockbox?(config())
  end

  test "section/button helpers build Slack-compatible maps" do
    section = Blocks.section("Hello", accessory: Blocks.button("Approve"))

    assert section["type"] == "section"
    assert section["text"]["type"] == "mrkdwn"
    assert section["accessory"]["type"] == "button"
  end

  test "falls back gracefully when BlockBox requested but not loaded" do
    log =
      capture_log(fn ->
        result = Blocks.build(config(block_builder: {:blockbox, []}), fn -> [:fallback] end)
        assert result == [:fallback]
      end)

    assert log =~ "block_builder set to :blockbox"
  end
end
