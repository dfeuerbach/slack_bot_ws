ExUnit.start()

defmodule SlackBot.TestHandler do
  @moduledoc false

  def handle_event(_type, _payload, _ctx), do: :ok
end
