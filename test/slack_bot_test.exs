defmodule SlackBotTest do
  use ExUnit.Case, async: true

  alias SlackBot.ConfigServer

  @valid_opts [
    app_token: "xapp-321",
    bot_token: "xoxb-321",
    module: SlackBot.TestHandler,
    name: SlackBotTest.Supervisor
  ]

  test "child_spec builds supervisor spec" do
    spec = SlackBot.child_spec(@valid_opts)

    assert spec.type == :supervisor
    assert spec.id == SlackBotTest.Supervisor
  end

  test "start_link boots supervisor tree" do
    start_supervised!({SlackBot, @valid_opts})

    assert %SlackBot.Config{} =
             ConfigServer.config(Module.concat(SlackBotTest.Supervisor, :ConfigServer))
  end
end
