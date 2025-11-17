defmodule SlackBot.Cache do
  @moduledoc """
  Placeholder cache facade. Real adapters arrive in later phases.
  """

  @spec channels(term()) :: []
  def channels(_config), do: []

  @spec users(term()) :: []
  def users(_config), do: []

  @spec put(term(), atom(), any()) :: :ok
  def put(_config, _type, _value), do: :ok
end
