defmodule SlackBot.SlashAck do
  @moduledoc false

  alias SlackBot.Config
  alias SlackBot.Telemetry

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

    respond(payload["response_url"], body, config)
  end

  def maybe_ack(_, _payload, _config), do: :ok

  defp respond(nil, _body, _config), do: :ok

  defp respond(url, body, %{ack_client: client} = config) do
    start = System.monotonic_time()

    result =
      try do
        client.post(url, body, config)
      rescue
        exception ->
          duration = System.monotonic_time() - start
          Telemetry.execute(config, [:ack, :http], %{duration: duration}, %{status: :exception})
          reraise exception, __STACKTRACE__
      else
        res ->
          duration = System.monotonic_time() - start

          Telemetry.execute(config, [:ack, :http], %{duration: duration}, %{
            status: ack_status(res)
          })

          res
      end

    normalize_ack_result(result)
  end

  defp ack_status(:ok), do: :ok
  defp ack_status({:ok, _}), do: :ok
  defp ack_status({:error, _}), do: :error
  defp ack_status(_), do: :unknown

  defp normalize_ack_result(_), do: :ok
end
