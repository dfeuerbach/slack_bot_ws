defmodule SlackBot.ConnectionManagerTest do
  use ExUnit.Case, async: true

  setup do
    Application.delete_env(:slack_bot_ws, SlackBot)

    config_opts = [
      app_token: "xapp-conn",
      bot_token: "xoxb-conn",
      module: SlackBot.TestHandler,
      transport: SlackBot.TestTransport,
      transport_opts: [notify: self()],
      http_client: SlackBot.TestHTTP,
      assigns: %{test_pid: self()}
    ]

    {:ok, _} = start_supervised({SlackBot.ConfigServer, name: :cm_config, config: config_opts})
    {:ok, _} = start_supervised({Task.Supervisor, name: :cm_tasks})

    {:ok, _pid} =
      start_supervised(
        {SlackBot.ConnectionManager,
         name: :cm_manager, config_server: :cm_config, task_supervisor: :cm_tasks}
      )

    assert_receive {:test_transport, transport_pid}

    %{transport: transport_pid}
  end

  test "dispatches events through handler", %{transport: transport_pid} do
    SlackBot.TestTransport.emit(transport_pid, "message", %{"text" => "hi"}, %{
      "envelope_id" => "E1"
    })

    assert_receive {:handled, "message", %{"text" => "hi"}, _ctx}
  end
end
