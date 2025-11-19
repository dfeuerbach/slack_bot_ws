ExUnit.start()

defmodule SlackBot.TestHandler do
  @moduledoc false

  def handle_event(type, payload, ctx) do
    if test_pid = ctx.assigns[:test_pid] do
      send(test_pid, {:handled, type, payload, ctx})
    end

    :ok
  end
end
