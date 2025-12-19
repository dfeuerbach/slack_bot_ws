defmodule SlackBot.RateLimiter.Timer do
  @moduledoc false

  @spec clamp(integer(), non_neg_integer()) :: non_neg_integer()
  def clamp(delay, min \\ 1) when is_integer(delay),
    do: max(delay, min)

  @spec schedule(map(), term(), term(), non_neg_integer(), (non_neg_integer() -> any())) :: map()
  def schedule(release_timers, key, method, delay, on_schedule) when is_integer(delay) do
    case Map.fetch(release_timers, key) do
      {:ok, _ref} ->
        release_timers

      :error ->
        ref = Process.send_after(self(), {:release_key, key}, delay)
        on_schedule.(delay)
        Map.put(release_timers, key, %{ref: ref, delay_ms: delay, method: method})
    end
  end

  @spec delay_ms(map()) :: integer() | nil
  def delay_ms(%{delay_ms: delay}) when is_integer(delay), do: delay
  def delay_ms(_), do: nil

  @spec method(map()) :: term()
  def method(%{method: method}) when not is_nil(method), do: method
  def method(_), do: :unknown
end
