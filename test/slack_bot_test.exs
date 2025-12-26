defmodule SlackBot.InstanceHelperBot do
  use SlackBot, otp_app: :slack_bot_ws

  handle_event "message", payload, ctx do
    SlackBot.TestHandler.handle_event("message", payload, ctx)
  end
end

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

    task =
      SlackBot.push_async(
        SlackBotTest.Supervisor,
        {"chat.postMessage", %{"text" => "async"}}
      )

    assert {:ok, %{"text" => "async"}} = Task.await(task)
  end

  describe "otp_app instance helpers" do
    setup do
      Application.put_env(:slack_bot_ws, SlackBot.InstanceHelperBot,
        app_token: "xapp-instance",
        bot_token: "xoxb-instance",
        transport: SlackBot.TestTransport,
        transport_opts: [notify: self()],
        http_client: SlackBot.TestHTTP,
        assigns: %{test_pid: self()}
      )

      on_exit(fn -> Application.delete_env(:slack_bot_ws, SlackBot.InstanceHelperBot) end)

      :ok
    end

    test "delegate to the running bot" do
      start_supervised!(SlackBot.InstanceHelperBot)
      assert_receive {:test_transport, _pid}

      assert %SlackBot.Config{module: SlackBot.InstanceHelperBot} =
               SlackBot.InstanceHelperBot.config()

      :ok = SlackBot.InstanceHelperBot.emit({"message", %{"text" => "emit helper"}})
      assert_receive {:handled, "message", %{"text" => "emit helper"}, _ctx}

      assert {:ok, %{"text" => "payload"}} =
               SlackBot.InstanceHelperBot.push({"chat.postMessage", %{"text" => "payload"}})

      task =
        SlackBot.InstanceHelperBot.push_async({"chat.postMessage", %{"text" => "async payload"}})

      assert {:ok, %{"text" => "async payload"}} = Task.await(task)
    end
  end
end
