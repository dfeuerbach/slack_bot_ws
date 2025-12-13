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

    assert_handler_stop(:ok, "ok-env")

    capture_log(fn ->
      SlackBot.TestTransport.emit(
        transport_pid,
        "message",
        %{"text" => "err", "handler_error" => true},
        %{"envelope_id" => "err-env"}
      )

      assert_handler_stop(:error, "err-env")

      SlackBot.TestTransport.emit(
        transport_pid,
        "message",
        %{"text" => "halt", "handler_halt" => true},
        %{"envelope_id" => "halt-env"}
      )

      assert_handler_stop(:halted, "halt-env")

      SlackBot.TestTransport.emit(
        transport_pid,
        "message",
        %{"text" => "boom", "raise" => true},
        %{
          "envelope_id" => "exc-env"
        }
      )

      assert_handler_stop(:exception, "exc-env")
    end)
  end

  defp assert_handler_stop(status, envelope_id, type \\ "message", timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_handler_stop(deadline, status, envelope_id, type)
  end

  defp wait_for_handler_stop(deadline, status, envelope_id, type) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:telemetry_event, [:slackbot, :handler, :dispatch, :stop], %{duration: _},
       %{status: ^status, envelope_id: ^envelope_id, type: ^type}} = event ->
        event

      _other ->
        wait_for_handler_stop(deadline, status, envelope_id, type)
    after
      remaining ->
        flunk("""
        expected handler stop telemetry with status=#{inspect(status)} envelope_id=#{inspect(envelope_id)} type=#{inspect(type)}
        """)
    end
  end
end
