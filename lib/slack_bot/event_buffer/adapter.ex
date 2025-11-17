defmodule SlackBot.EventBuffer.Adapter do
  @moduledoc """
  Behaviour for event buffer adapters.
  """

  @callback init(keyword()) :: {:ok, term()}
  @callback record(term(), String.t(), map()) :: {:ok, term()}
  @callback delete(term(), String.t()) :: {:ok, term()}
  @callback seen?(term(), String.t()) :: {boolean(), term()}
  @callback pending(term()) :: {list(), term()}
end
