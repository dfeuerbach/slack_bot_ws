defmodule SlackBot.ConnectionManagerTest do
  use ExUnit.Case, async: true

  alias SlackBot.Cache
  alias SlackBot.EventBuffer

  setup do
    Application.delete_env(:slack_bot_ws, SlackBot)

    instance = ConnectionManagerTest.Instance

    config_opts = [
      app_token: "xapp-conn",
      bot_token: "xoxb-conn",
      module: SlackBot.TestHandler,
      transport: SlackBot.TestTransport,
      transport_opts: [notify: self()],
      http_client: SlackBot.TestHTTP,
      assigns: %{test_pid: self(), bot_user_id: "B1"},
      instance_name: instance
    ]

    {:ok, _} = start_supervised({SlackBot.ConfigServer, name: :cm_config, config: config_opts})
    config = SlackBot.ConfigServer.config(:cm_config)

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    start_supervised!(EventBuffer.child_spec(config))

    {:ok, _} = start_supervised({Task.Supervisor, name: :cm_tasks})

    {:ok, _pid} =
      start_supervised(
        {SlackBot.ConnectionManager,
         name: :cm_manager, config_server: :cm_config, task_supervisor: :cm_tasks}
      )

    assert_receive {:test_transport, transport_pid}

    %{transport: transport_pid, config: config}
  end

  test "dispatches events through handler", %{transport: transport_pid} do
    SlackBot.TestTransport.emit(transport_pid, "message", %{"text" => "hi"}, %{
      "envelope_id" => "E1"
    })

    assert_receive {:handled, "message", %{"text" => "hi"}, _ctx}
  end

  test "ignores duplicate envelopes", %{transport: transport_pid} do
    envelope = %{"envelope_id" => "E-dup"}

    SlackBot.TestTransport.emit(transport_pid, "message", %{"text" => "hi"}, envelope)
    SlackBot.TestTransport.emit(transport_pid, "message", %{"text" => "hi"}, envelope)

    assert_receive {:handled, "message", %{"text" => "hi"}, _ctx}
    refute_receive {:handled, "message", %{"text" => "hi"}, _ctx}, 50
  end

  test "updates cache on channel join/part", %{transport: transport_pid, config: config} do
    SlackBot.TestTransport.emit(
      transport_pid,
      "member_joined_channel",
      %{
        "channel" => "C123",
        "user" => "B1"
      },
      %{"envelope_id" => "E2"}
    )

    assert_receive {:handled, "member_joined_channel", _payload, _ctx}
    assert Cache.channels(config) == ["C123"]

    SlackBot.TestTransport.emit(
      transport_pid,
      "channel_left",
      %{
        "channel" => "C123",
        "user" => "B1"
      },
      %{"envelope_id" => "E3"}
    )

    assert_receive {:handled, "channel_left", _payload, _ctx}
    assert Cache.channels(config) == []
  end
end
