defmodule SlackBot.SlashAck.HTTP do
  @moduledoc false

  @behaviour SlackBot.SlashAck.HttpClient

  alias SlackBot.Config

  @impl true
  def post(url, body, %Config{} = config) when is_binary(url) and is_map(body) do
    request =
      :post
      |> Finch.build(url, [{"content-type", "application/json"}], Jason.encode!(body))

    case Finch.request(request, ack_pool_name(config)) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ack_pool_name(%Config{instance_name: instance}) when is_atom(instance) do
    Module.concat(instance, :AckFinch)
  end
end
