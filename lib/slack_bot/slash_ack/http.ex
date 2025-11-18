defmodule SlackBot.SlashAck.HTTP do
  @moduledoc false

  @behaviour SlackBot.SlashAck.HttpClient

  @impl true
  def post(url, body) when is_binary(url) and is_map(body) do
    Req.post!(url: url, json: body)
    :ok
  end
end
