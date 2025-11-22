defmodule SlackBot.EventBuffer.Adapter do
  @moduledoc """
  Behaviour for event buffer adapters.

  `record/3` must return `:ok` for newly inserted envelopes or `:duplicate` when the key
  already exists, enabling the connection manager to dedupe envelopes in a single call.
  """

  @callback init(keyword()) :: {:ok, term()}
  @callback record(term(), String.t(), map()) :: {:ok | :duplicate, term()}
  @callback delete(term(), String.t()) :: {:ok, term()}
  @callback seen?(term(), String.t()) :: {boolean(), term()}
  @callback pending(term()) :: {list(), term()}
end
