defmodule SlackBot.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias SlackBot.Config
  alias SlackBot.Diagnostics

  setup do
    config =
      %Config{
        app_token: "xapp-diag",
        bot_token: "xoxb-diag",
        module: SlackBot.TestHandler,
        instance_name: DiagnosticsTest.Instance,
        diagnostics: %{enabled: true, buffer_size: 2}
      }

    start_supervised!(Diagnostics.child_spec(config))

    %{config: config}
  end

  test "records entries respecting buffer size", %{config: config} do
    Diagnostics.record(config, :inbound, %{type: "message", payload: %{"text" => "one"}})
    Diagnostics.record(config, :inbound, %{type: "message", payload: %{"text" => "two"}})
    Diagnostics.record(config, :inbound, %{type: "message", payload: %{"text" => "three"}})

    entries = Diagnostics.list(config)
    assert length(entries) == 2
    assert Enum.map(entries, & &1.payload["text"]) == ["three", "two"]
  end

  test "filters by direction and type", %{config: config} do
    Diagnostics.record(config, :inbound, %{type: "message", payload: %{}})
    Diagnostics.record(config, :outbound, %{type: "ack", payload: %{}})

    inbound = Diagnostics.list(config, direction: :inbound)
    assert Enum.all?(inbound, &(&1.direction == :inbound))

    outbound = Diagnostics.list(config, direction: :outbound, types: ["ack"])
    assert [%{type: "ack"}] = Enum.take(outbound, 1)
  end

  test "replays entries via custom dispatch", %{config: config} do
    Diagnostics.record(config, :inbound, %{type: "message", payload: %{"text" => "hi"}})

    {:ok, count} =
      Diagnostics.replay(config,
        dispatch: fn entry -> send(self(), {:replayed, entry.payload["text"]}) end
      )

    assert count == 1
    assert_receive {:replayed, "hi"}
  end

  test "record emits telemetry events", %{config: config} do
    parent = self()
    handler_id = {:diag_record, make_ref()}

    :telemetry.attach(handler_id, [:slackbot, :diagnostics, :record], &__MODULE__.record_handler/4, parent)

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Diagnostics.record(config, :inbound, %{type: "message", payload: %{}})

    assert_receive {:telemetry_event, [:slackbot, :diagnostics, :record], %{count: 1},
                    %{direction: :inbound}}
  end

  test "replay emits telemetry events", %{config: config} do
    Diagnostics.record(config, :inbound, %{type: "message", payload: %{}})

    parent = self()
    handler_id = {:diag_replay, make_ref()}

    :telemetry.attach(handler_id, [:slackbot, :diagnostics, :replay], &__MODULE__.record_handler/4, parent)

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _} = Diagnostics.replay(config, dispatch: fn _ -> :ok end)

    assert_receive {:telemetry_event, [:slackbot, :diagnostics, :replay], %{count: 1}, metadata}
    assert metadata.filters[:direction] == :inbound
  end

  test "clears buffer", %{config: config} do
    Diagnostics.record(config, :inbound, %{type: "message", payload: %{}})
    assert Diagnostics.list(config) |> length() == 1

    Diagnostics.clear(config)
    assert Diagnostics.list(config) == []
  end

  def record_handler(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end
end
