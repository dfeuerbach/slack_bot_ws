defmodule SlackBot.SlashAck do
  @moduledoc false

  alias SlackBot.Config

  @default_text "Processing…"

  @spec maybe_ack(:silent | :ephemeral | {:custom, function()}, map(), Config.t()) :: :ok
  def maybe_ack(:silent, _payload, _config), do: :ok

  def maybe_ack({:custom, fun}, payload, config) when is_function(fun, 2),
    do: fun.(payload, config)

  def maybe_ack(:ephemeral, payload, config) do
    text = Map.get(config.assigns, :slash_ack_text, @default_text)

    body = %{
      response_type: "ephemeral",
      text: text,
      replace_original: false
    }

    respond(payload["response_url"], body, config.ack_client)
  end

  def maybe_ack(_, _payload, _config), do: :ok

  defp respond(nil, _body, _client), do: :ok

  defp respond(url, body, client) do
    client.post(url, body)
    :ok
  end
end
