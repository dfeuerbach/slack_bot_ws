defmodule SlackBot.Logging do
  @moduledoc """
  Structured logging helpers for SlackBot.

  Use `with_envelope/3` to temporarily attach metadata (envelope id, event type, channel,
  user) while executing code that emits `Logger` messages.
  """

  require Logger

  @type envelope :: map() | nil
  @type payload :: map() | nil

  @doc """
  Executes `fun` after attaching metadata derived from the envelope/payload.

  Automatically resets the metadata keys once `fun` returns.
  """
  @spec with_envelope(envelope(), payload(), (-> term())) :: term()
  def with_envelope(envelope, payload, fun) when is_function(fun, 0) do
    metadata = metadata(envelope, payload)
    Logger.metadata(metadata)

    try do
      fun.()
    after
      Logger.reset_metadata(Enum.map(metadata, &elem(&1, 0)))
    end
  end

  @doc """
  Generates `Logger` metadata for the provided envelope/payload.
  """
  @spec metadata(envelope(), payload(), keyword()) :: keyword()
  def metadata(envelope, payload, extra \\ []) do
    [
      slack_envelope_id: envelope_id(envelope),
      slack_event_type: payload_type(payload),
      slack_channel: channel(payload),
      slack_user: user(payload)
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Keyword.merge(extra)
  end

  defp envelope_id(%{"envelope_id" => id}), do: id
  defp envelope_id(_), do: nil

  defp payload_type(%{"type" => type}), do: type
  defp payload_type(%{"event" => %{"type" => type}}), do: type
  defp payload_type(_), do: nil

  defp channel(%{"channel" => channel}), do: channel
  defp channel(%{"event" => %{"channel" => channel}}), do: channel
  defp channel(_), do: nil

  defp user(%{"user" => user}), do: user
  defp user(%{"event" => %{"user" => user}}), do: user
  defp user(_), do: nil
end
