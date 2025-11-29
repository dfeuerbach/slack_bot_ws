defmodule SlackBot.ConnectionTelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SlackBot.Cache
  alias SlackBot.EventBuffer

  setup do
    Application.delete_env(:slack_bot_ws, SlackBot)

    instance = __MODULE__.Instance

    config_opts = [
      app_token: "xapp-telemetry",
      bot_token: "xoxb-telemetry",
      module: SlackBot.TestHandler,
      transport: SlackBot.TestTransport,
      transport_opts: [notify: self()],
      http_client: SlackBot.TestHTTP,
      assigns: %{test_pid: self()},
      instance_name: instance
    ]

    {:ok, _} = start_supervised({SlackBot.ConfigServer, name: :ct_config, config: config_opts})
    config = SlackBot.ConfigServer.config(:ct_config)

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    start_supervised!(EventBuffer.child_spec(config))
    {:ok, _} = start_supervised({Task.Supervisor, name: :ct_tasks})

    {:ok, %{config: config}}
  end

  test "emits telemetry on connect and disconnect", %{config: _config} do
    parent = self()
    handler_id = {:conn_state, make_ref()}

    :telemetry.attach(
      handler_id,
      [:slackbot, :connection, :state],
      fn event, measurements, metadata, _ ->
        send(parent, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    capture_log(fn ->
      {:ok, _pid} =
        start_supervised(
          {SlackBot.ConnectionManager,
           name: :ct_manager, config_server: :ct_config, task_supervisor: :ct_tasks}
        )

      assert_receive {:test_transport, transport_pid}

      assert_receive {:telemetry_event, [:slackbot, :connection, :state], %{count: 1},
                      %{state: :connected}}

      SlackBot.TestTransport.disconnect(transport_pid, %{"reason" => "refresh"})

      assert_receive {:telemetry_event, [:slackbot, :connection, :state], %{count: 1},
                      %{state: :disconnect, reason: %{"reason" => "refresh"}}}
    end)
  end

  test "emits handler ingress telemetry for queued and duplicate envelopes", %{config: _config} do
    parent = self()
    handler_id = {:handler_ingress, make_ref()}

    :telemetry.attach(
      handler_id,
      [:slackbot, :handler, :ingress],
      fn event, measurements, metadata, _ ->
        send(parent, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _pid} =
      start_supervised(
        {SlackBot.ConnectionManager,
         name: :ct_ingress_manager, config_server: :ct_config, task_supervisor: :ct_tasks}
      )

    assert_receive {:test_transport, transport_pid}

    SlackBot.TestTransport.emit(transport_pid, "message", %{"text" => "hi"},
      %{"envelope_id" => "ENV-1"}
    )

    assert_receive {:telemetry_event, [:slackbot, :handler, :ingress], %{count: 1},
                    %{decision: :queue, envelope_id: "ENV-1", type: "message"}}

    SlackBot.TestTransport.emit(transport_pid, "message", %{"text" => "hi"},
      %{"envelope_id" => "ENV-1"}
    )

    assert_receive {:telemetry_event, [:slackbot, :handler, :ingress], %{count: 1},
                    %{decision: :duplicate, envelope_id: "ENV-1", type: "message"}}
  end

  test "annotates handler spans with envelope ids and statuses", %{config: _config} do
    parent = self()
    handler_id = {:handler_span, make_ref()}

    :telemetry.attach(
      handler_id,
      [:slackbot, :handler, :dispatch, :stop],
      fn event, measurements, metadata, _ ->
        send(parent, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _pid} =
      start_supervised(
        {SlackBot.ConnectionManager,
         name: :ct_span_manager, config_server: :ct_config, task_supervisor: :ct_tasks}
      )

    assert_receive {:test_transport, transport_pid}

    SlackBot.TestTransport.emit(transport_pid, "message", %{"text" => "ok"},
      %{"envelope_id" => "ok-env"}
    )

    assert_receive {:telemetry_event, [:slackbot, :handler, :dispatch, :stop], %{duration: _},
                    %{status: :ok, envelope_id: "ok-env", type: "message"}}

    SlackBot.TestTransport.emit(transport_pid, "message", %{"text" => "err", "handler_error" => true},
      %{"envelope_id" => "err-env"}
    )

    assert_receive {:telemetry_event, [:slackbot, :handler, :dispatch, :stop], %{duration: _},
                    %{status: :error, envelope_id: "err-env", type: "message"}}

    SlackBot.TestTransport.emit(transport_pid, "message", %{"text" => "halt", "handler_halt" => true},
      %{"envelope_id" => "halt-env"}
    )

    assert_receive {:telemetry_event, [:slackbot, :handler, :dispatch, :stop], %{duration: _},
                    %{status: :halted, envelope_id: "halt-env", type: "message"}}

    SlackBot.TestTransport.emit(transport_pid, "message", %{"text" => "boom", "raise" => true},
      %{"envelope_id" => "exc-env"}
    )

    assert_receive {:telemetry_event, [:slackbot, :handler, :dispatch, :stop], %{duration: _},
                    %{status: :exception, envelope_id: "exc-env", type: "message"}}
  end
end
