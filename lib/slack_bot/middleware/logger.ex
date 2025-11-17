defmodule SlackBot.Middleware.Logger do
  @moduledoc """
  Simple middleware that logs incoming events.
  """

  require Logger

  def call(type, payload, ctx) do
    Logger.debug("[SlackBot] event=#{type} payload=#{inspect(payload)}")
    {:cont, payload, ctx}
  end
end
