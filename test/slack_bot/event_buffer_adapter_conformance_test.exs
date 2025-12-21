defmodule SlackBot.EventBufferAdapterConformanceTest do
  use ExUnit.Case, async: true

  alias SlackBot.EventBufferConformance.Runner
  alias SlackBot.EventBufferConformance.Scenarios
  alias SlackBot.EventBufferConformance.TelemetryProbe

  @backends [:ets, :redis]
  @scenarios Scenarios.all()

  for backend <- @backends, {name, fun_atom} <- @scenarios do
    test "#{backend} #{name}" do
      %{config: config, cleanup: cleanup} = Runner.start!(unquote(backend), ttl_ms: 200)
      handler_id = TelemetryProbe.attach!(config, self())

      try do
        apply(Scenarios, unquote(fun_atom), [%{config: config}])
      after
        TelemetryProbe.detach(handler_id)
        cleanup.()
      end
    end
  end
end
