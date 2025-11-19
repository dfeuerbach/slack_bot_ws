defmodule SlackBot.BackoffTest do
  use ExUnit.Case, async: true

  alias SlackBot.Backoff

  @backoff %{min_ms: 1000, max_ms: 30_000, jitter_ratio: 0.2}

  test "grows exponentially until capped" do
    assert Backoff.next_delay(@backoff, 1) in 800..1_200
    assert Backoff.next_delay(@backoff, 5) <= 30_000
  end

  test "applies deterministic jitter with seeded RNG" do
    :rand.seed(:exsplus, {101, 102, 103})
    delay = Backoff.next_delay(@backoff, 2)
    assert delay in 1600..2400
    refute delay == 2000
  end

  test "respects jitter_ratio of zero" do
    :rand.seed(:exsplus, {1, 2, 3})
    assert Backoff.next_delay(%{@backoff | jitter_ratio: 0}, 3) == 4000
  end
end
