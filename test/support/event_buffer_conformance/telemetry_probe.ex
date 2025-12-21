defmodule SlackBot.EventBufferConformance.TelemetryProbe do
  @moduledoc false

  def attach!(config, test_pid) do
    prefix = config.telemetry_prefix

    handler_id = {:event_buffer_probe, self(), System.unique_integer([:positive])}

    :telemetry.attach_many(
      handler_id,
      [
        prefix ++ [:event_buffer, :record],
        prefix ++ [:event_buffer, :delete],
        prefix ++ [:event_buffer, :seen],
        prefix ++ [:event_buffer, :pending]
      ],
      &__MODULE__.handle_event/4,
      %{test_pid: test_pid}
    )

    handler_id
  end

  def detach(handler_id) do
    :telemetry.detach(handler_id)
  end

  def handle_event(event, measurements, metadata, %{test_pid: pid}) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end
end
