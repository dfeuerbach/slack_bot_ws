defmodule SlackBotTest do
  use ExUnit.Case, async: true

  alias SlackBot.ConfigServer

  setup do
    Application.delete_env(:slack_bot_ws, SlackBot)
    :ok
  end

  defp valid_opts(notify \\ self()) do
    [
      app_token: "xapp-321",
      bot_token: "xoxb-321",
      module: SlackBot.TestHandler,
      name: SlackBotTest.Supervisor,
      transport: SlackBot.TestTransport,
      transport_opts: [notify: notify],
      http_client: SlackBot.TestHTTP,
      assigns: %{test_pid: notify}
    ]
  end

  test "child_spec builds supervisor spec" do
    spec = SlackBot.child_spec(valid_opts())

    assert spec.type == :supervisor
    assert spec.id == SlackBotTest.Supervisor
  end

  test "start_link boots supervisor tree" do
    start_supervised!({SlackBot, valid_opts()})

    assert %SlackBot.Config{} =
             ConfigServer.config(Module.concat(SlackBotTest.Supervisor, :ConfigServer))
  end

  test "emit and push helpers" do
    start_supervised!({SlackBot, valid_opts()})
    assert_receive {:test_transport, _pid}

    :ok = SlackBot.emit(SlackBotTest.Supervisor, {"message", %{"text" => "emit"}})
    assert_receive {:handled, "message", %{"text" => "emit"}, _ctx}

    assert {:ok, %{"text" => "payload"}} =
             SlackBot.push(SlackBotTest.Supervisor, {"chat.postMessage", %{"text" => "payload"}})
  end
end
