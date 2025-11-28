defmodule SlackBot.API do
  @moduledoc false

  @slack_base "https://slack.com/api/"

  alias SlackBot.Config
  alias SlackBot.TierLimiter
  require Logger

  @spec apps_connections_open(Config.t()) ::
          {:ok, String.t()}
          | {:rate_limited, non_neg_integer()}
          | {:error, term()}
  def apps_connections_open(%Config{} = config) do
    :ok = TierLimiter.acquire(config, "apps.connections.open", %{})

    case post_with_token(config, config.app_token, "apps.connections.open", %{}) do
      {:ok, %{"url" => url}} ->
        {:ok, url}

      {:error, {:rate_limited, secs}} ->
        TierLimiter.suspend(config, "apps.connections.open", %{}, secs * 1_000)
        {:rate_limited, secs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec post(Config.t(), String.t(), map()) ::
          {:ok, map()}
          | {:error, {:rate_limited, non_neg_integer()}}
          | {:error, term()}
  def post(%Config{} = config, method, body) when is_binary(method) and is_map(body) do
    :ok = TierLimiter.acquire(config, method, body)

    case post_with_token(config, config.bot_token, method, body) do
      {:error, {:rate_limited, secs}} = error ->
        TierLimiter.suspend(config, method, body, secs * 1_000)
        error

      other ->
        other
    end
  end

  defp post_with_token(%Config{} = config, token, method, body) when is_binary(method) do
    headers = [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/json"}
    ]

    with {:ok, response} <-
           request(
             url: @slack_base <> method,
             headers: headers,
             json: body,
             finch: finch_name(config)
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
    header_retry_after =
      case response do
        %{headers: headers} ->
          headers
          |> Enum.find_value(fn {k, v} -> if String.downcase(k) == "retry-after", do: v end)

        _ ->
          nil
      end

    body_retry_after = body["retry_after"]

    raw_retry_after = body_retry_after || header_retry_after

    retry_after =
      case raw_retry_after do
        [value | _] -> to_integer(value, 1)
        value -> to_integer(value, 1)
      end

    {:error, {:rate_limited, retry_after}}
  end

  defp interpret_response(%{"ok" => false, "error" => error}, _response),
    do: {:error, {:slack_error, error}}

  defp interpret_response(other, _response), do: {:error, {:invalid_body, other}}

  defp finch_name(%Config{instance_name: instance}) when is_atom(instance) do
    Module.concat(instance, :APIFinch)
  end

  defp request(opts) when is_list(opts) do
    req_module()
    |> apply(:post, [opts])
  end

  defp req_module do
    Application.get_env(:slack_bot_ws, __MODULE__, [])
    |> Keyword.get(:req_impl, Req)
  end

  defp to_integer(nil, default), do: default
  defp to_integer(value, _default) when is_binary(value), do: String.to_integer(value)
  defp to_integer(value, _default) when is_integer(value), do: value
  defp to_integer(_, default), do: default
end
