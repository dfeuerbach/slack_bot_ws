defmodule SlackBot.TierRegistry do
  @moduledoc false

  @default_tiers %{
    "users.list" => %{
      tier: :tier2,
      window_ms: 60_000,
      max_calls: 20,
      scope: :workspace,
      group: :metadata_catalog,
      burst_ratio: 0.25,
      initial_fill_ratio: 0.5
    },
    "users.conversations" => %{
      tier: :tier2,
      window_ms: 60_000,
      max_calls: 20,
      scope: :workspace,
      group: :metadata_catalog,
      burst_ratio: 0.25,
      initial_fill_ratio: 0.5
    }
  }

  @doc """
  Returns the tier specification for a given Slack Web API method.

  Specs can be overridden via `config :slack_bot_ws, SlackBot.TierRegistry,
  tiers: %{ "users.list" => %{max_calls: 10, window_ms: 30_000} }`.
  """
  @spec lookup(String.t()) :: {:ok, map()} | :error
  def lookup(method) when is_binary(method) do
    tiers()
    |> Map.fetch(method)
    |> case do
      {:ok, spec} -> {:ok, normalize_spec(spec)}
      :error -> :error
    end
  end

  defp tiers do
    overrides =
      Application.get_env(:slack_bot_ws, __MODULE__, [])
      |> Keyword.get(:tiers, %{})

    Map.merge(@default_tiers, overrides)
  end

  defp normalize_spec(spec) do
    %{
      tier: Map.get(spec, :tier, :custom),
      window_ms: Map.get(spec, :window_ms) || Map.get(spec, :window, 60_000),
      max_calls: Map.get(spec, :max_calls) || Map.get(spec, :limit, 20),
      scope: Map.get(spec, :scope, :workspace),
      group: Map.get(spec, :group),
      burst_ratio: Map.get(spec, :burst_ratio, 0.25),
      capacity: Map.get(spec, :capacity),
      initial_fill_ratio: Map.get(spec, :initial_fill_ratio, 0.5)
    }
  end
end
