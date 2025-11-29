ExUnit.start()

defmodule SlackBot.TestHandler do
  @moduledoc false

  def handle_event(type, payload, ctx) do
    if test_pid = ctx.assigns[:test_pid] do
      send(test_pid, {:handled, type, payload, ctx})
    end

    cond do
      truthy?(payload["raise"]) ->
        raise "forced-test-error"

      truthy?(payload["handler_error"]) ->
        {:error, :forced_error}

      truthy?(payload["handler_halt"]) ->
        {:halt, :forced_halt}

      true ->
        :ok
    end
  end

  defp truthy?(value), do: value in [true, "true", 1]
end
