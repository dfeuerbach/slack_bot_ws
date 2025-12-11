defmodule SlackBot.ConnectionTelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import SlackBot.ConnectionTestHelpers

  alias SlackBot.Cache
  alias SlackBot.EventBuffer

  setup do
    Application.delete_env(:slack_bot_ws, SlackBot)

    config_name = unique_name(:ct_config)
    task_sup_name = unique_name(:ct_tasks)
    instance = Module.concat(__MODULE__, :"Instance#{System.unique_integer([:positive])}")

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

    {:ok, _} =
      start_supervised({SlackBot.ConfigServer, name: config_name, config: config_opts})

    config = SlackBot.ConfigServer.config(config_name)

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    start_supervised!(EventBuffer.child_spec(config))
    {:ok, _} = start_supervised({Task.Supervisor, name: task_sup_name})

    {:ok, %{config: config, config_name: config_name, task_sup: task_sup_name}}
  end

  test "emits telemetry on connect and disconnect", %{
    config_name: config_name,
    task_sup: task_sup_name
  } do
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
           name: unique_name(:ct_manager),
           config_server: config_name,
           task_supervisor: task_sup_name}
        )

      assert_receive {:test_transport, transport_pid}

      _ = assert_conn_state(:connected)

      SlackBot.TestTransport.disconnect(transport_pid, %{"reason" => "refresh"})

      {_measurements, metadata} = assert_conn_state(:disconnect)
      assert metadata[:reason] == %{"reason" => "refresh"}
    end)
  end

  test "emits handler ingress telemetry for queued and duplicate envelopes", %{
    config_name: config_name,
    task_sup: task_sup_name
  } do
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
         name: unique_name(:ct_ingress_manager),
         config_server: config_name,
         task_supervisor: task_sup_name}
      )

    assert_receive {:test_transport, transport_pid}

    SlackBot.TestTransport.emit(transport_pid, "message", %{"text" => "hi"}, %{
      "envelope_id" => "ENV-1"
    })

    assert_receive {:telemetry_event, [:slackbot, :handler, :ingress], %{count: 1},
                    %{decision: :queue, envelope_id: "ENV-1", type: "message"}}

    SlackBot.TestTransport.emit(transport_pid, "message", %{"text" => "hi"}, %{
      "envelope_id" => "ENV-1"
    })

    assert_receive {:telemetry_event, [:slackbot, :handler, :ingress], %{count: 1},
                    %{decision: :duplicate, envelope_id: "ENV-1", type: "message"}}
  end

  test "annotates handler spans with envelope ids and statuses", %{
    config_name: config_name,
    task_sup: task_sup_name
  } do
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
         name: unique_name(:ct_span_manager),
         config_server: config_name,
         task_supervisor: task_sup_name}
      )

    assert_receive {:test_transport, transport_pid}

    SlackBot.TestTransport.emit(transport_pid, "message", %{"text" => "ok"}, %{
      "envelope_id" => "ok-env"
    })

    assert_receive {:telemetry_event, [:slackbot, :handler, :dispatch, :stop], %{duration: _},
                    %{status: :ok, envelope_id: "ok-env", type: "message"}}

    SlackBot.TestTransport.emit(
      transport_pid,
      "message",
      %{"text" => "err", "handler_error" => true},
      %{"envelope_id" => "err-env"}
    )

    assert_receive {:telemetry_event, [:slackbot, :handler, :dispatch, :stop], %{duration: _},
                    %{status: :error, envelope_id: "err-env", type: "message"}}

    SlackBot.TestTransport.emit(
      transport_pid,
      "message",
      %{"text" => "halt", "handler_halt" => true},
      %{"envelope_id" => "halt-env"}
    )

    assert_receive {:telemetry_event, [:slackbot, :handler, :dispatch, :stop], %{duration: _},
                    %{status: :halted, envelope_id: "halt-env", type: "message"}}

    SlackBot.TestTransport.emit(transport_pid, "message", %{"text" => "boom", "raise" => true}, %{
      "envelope_id" => "exc-env"
    })

    assert_receive {:telemetry_event, [:slackbot, :handler, :dispatch, :stop], %{duration: _},
                    %{status: :exception, envelope_id: "exc-env", type: "message"}}
  end
end
