defmodule SlackBot.Telemetry do
  @moduledoc false

  @doc """
  Executes a Telemetry event by appending `suffix` to the instance prefix.
  """
  @spec execute(SlackBot.Config.t(), [atom()], map(), map()) :: :ok
  def execute(%{telemetry_prefix: prefix}, suffix, measurements, metadata) do
    :telemetry.execute(prefix ++ suffix, measurements, metadata)
  end

  @doc """
  Wraps a function in `:telemetry.span/3`, automatically handling event naming.
  """
  @spec span(SlackBot.Config.t(), [atom()], map(), (-> {term(), map()})) ::
          {term(), map()}
  def span(%{telemetry_prefix: prefix}, suffix, metadata, fun) when is_function(fun, 0) do
    :telemetry.span(prefix ++ suffix, metadata, fun)
  end
end
