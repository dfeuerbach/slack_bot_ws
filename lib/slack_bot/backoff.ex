defmodule SlackBot.Backoff do
  @moduledoc false

  @spec next_delay(%{min_ms: pos_integer(), max_ms: pos_integer(), jitter_ratio: number()}, pos_integer()) ::
          pos_integer()
  def next_delay(%{min_ms: min_ms, max_ms: max_ms} = backoff, attempt) when attempt >= 1 do
    base =
      min(
        max_ms,
        min_ms * :math.pow(2, attempt - 1)
      )
      |> trunc()

    apply_jitter(base, Map.get(backoff, :jitter_ratio, 0.0))
  end

  defp apply_jitter(base, ratio) when ratio > 0 do
    min_factor = max(0.0, 1.0 - ratio)
    max_factor = 1.0 + ratio
    factor = :rand.uniform() * (max_factor - min_factor) + min_factor
    max(trunc(base * factor), 1)
  end

  defp apply_jitter(base, _ratio), do: max(base, 1)
end
