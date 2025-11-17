defmodule SlackBot.EventBuffer do
  @moduledoc """
  Stub implementation that can be replaced with real adapters in future phases.
  """

  @type key :: String.t()
  @type payload :: map()

  @spec record(term(), key(), payload()) :: :ok
  def record(_config, _key, _payload), do: :ok

  @spec delete(term(), key()) :: :ok
  def delete(_config, _key), do: :ok

  @spec seen?(term(), key()) :: boolean()
  def seen?(_config, _key), do: false
end
