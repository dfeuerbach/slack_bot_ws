defmodule SlackBot.RateLimiterAdapterETSTest do
  use ExUnit.Case, async: true

  alias SlackBot.RateLimiter.Adapters.ETS

  test "shares blocked state across adapter instances via table option" do
    table = :rate_limiter_multi_instance_table
    key = {:channel, "C-shared"}

    config1 =
      struct!(SlackBot.Config, %{
        app_token: "xapp-1",
        bot_token: "xoxb-1",
        module: SlackBot.TestHandler,
        instance_name: __MODULE__
      })

    config2 =
      struct!(SlackBot.Config, %{
        app_token: "xapp-2",
        bot_token: "xoxb-2",
        module: SlackBot.TestHandler,
        instance_name: __MODULE__.Other
      })

    {:ok, state1} = ETS.init(config1, table: table)
    {:ok, state2} = ETS.init(config2, table: table)

    now = System.monotonic_time(:millisecond)

    # First instance records a rate-limited result for the key.
    {:ok, _new_state1} = ETS.record_result(state1, key, now, {:error, {:rate_limited, 1}})

    # Second instance should observe the same blocked window via the shared ETS table.
    {blocked_until, state2} = ETS.blocked_until(state2, key, now)

    assert is_integer(blocked_until)
    assert blocked_until > now

    # Block eventually expires when queried after TTL or elapsed time.
    {value, _} = ETS.blocked_until(state2, key, blocked_until + 1)
    assert value == nil
  end
end
