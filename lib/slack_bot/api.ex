defmodule SlackBot.API do
  @moduledoc """
  Minimal Slack Web API client used by SlackBot runtime.
  """

  @slack_base "https://slack.com/api/"

  @spec apps_connections_open(String.t()) ::
          {:ok, String.t()}
          | {:rate_limited, non_neg_integer()}
          | {:error, term()}
  def apps_connections_open(app_token) do
    case post("apps.connections.open", app_token, %{}) do
      {:ok, %{"url" => url}} ->
        {:ok, url}

      {:error, {:rate_limited, secs}} ->
        {:rate_limited, secs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec post(String.t(), String.t(), map()) ::
          {:ok, map()}
          | {:error, {:rate_limited, non_neg_integer()}}
          | {:error, term()}
  def post(method, token, body) when is_binary(method) do
    headers = [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/json"}
    ]

    with {:ok, response} <-
           Req.post(
             url: @slack_base <> method,
             headers: headers,
             json: body
           ),
         {:ok, decoded} <- decode_body(response) do
      interpret_response(decoded, response)
    end
  end

  defp decode_body(%{body: %{} = map}), do: {:ok, map}
  defp decode_body(%{body: body}) when is_binary(body), do: Jason.decode(body)
  defp decode_body(_), do: {:error, :invalid_response}

  defp interpret_response(%{"ok" => true} = body, _response), do: {:ok, body}

  defp interpret_response(%{"ok" => false, "error" => "ratelimited"} = body, response) do
    retry_after =
      body["retry_after"] ||
        response.headers
        |> Enum.find_value(fn {k, v} -> if String.downcase(k) == "retry-after", do: v end)
        |> to_integer(1)

    {:error, {:rate_limited, retry_after}}
  end

  defp interpret_response(%{"ok" => false, "error" => error}, _response),
    do: {:error, {:slack_error, error}}

  defp interpret_response(other, _response), do: {:error, {:invalid_body, other}}

  defp to_integer(nil, default), do: default
  defp to_integer(value, _default) when is_binary(value), do: String.to_integer(value)
  defp to_integer(value, _default) when is_integer(value), do: value
  defp to_integer(_, default), do: default
end
