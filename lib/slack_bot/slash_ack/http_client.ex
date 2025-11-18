defmodule SlackBot.SlashAck.HttpClient do
  @moduledoc """
  Behaviour for slash command acknowledgement HTTP clients.

  Provide a custom implementation via `%SlackBot.Config{ack_client: MyClient}` when you
  need to control how response URLs are invoked during auto-ack flows.
  """

  @callback post(String.t(), map()) :: :ok | {:error, term()}
end
