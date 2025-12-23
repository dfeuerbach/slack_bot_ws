defmodule SlackBot.EventBufferConformance.Scenarios do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias SlackBot.EventBuffer

  @spec all() :: list({String.t(), atom()})
  def all do
    [
      {"nil key handling", :nil_key},
      {"basic dedupe", :basic_dedupe},
      {"pending determinism", :pending_determinism},
      {"delete removes from pending", :delete_removes},
      {"first write wins payload", :first_write_wins},
      {"ttl expiry affects seen and pending", :ttl_expiry},
      {"ttl refresh on duplicate", :ttl_refresh},
      {"namespace isolation", :isolation},
      {"concurrent record race", :concurrent_race}
    ]
  end

  def nil_key(%{config: config}) do
    assert :ok = EventBuffer.record(config, nil, %{payload: :ignored})
    refute EventBuffer.seen?(config, nil)
    assert :ok = EventBuffer.delete(config, nil)
  end

  def basic_dedupe(%{config: config}) do
    assert :ok = EventBuffer.record(config, "k1", %{p: :a})
    assert :duplicate = EventBuffer.record(config, "k1", %{p: :a})
    assert EventBuffer.seen?(config, "k1")
    assert :ok = EventBuffer.delete(config, "k1")
    refute EventBuffer.seen?(config, "k1")
  end

  def pending_determinism(%{config: config}) do
    assert :ok = EventBuffer.record(config, "k1", %{p: 1})
    Process.sleep(10)
    assert :ok = EventBuffer.record(config, "k2", %{p: 2})
    Process.sleep(10)
    assert :ok = EventBuffer.record(config, "k3", %{p: 3})

    assert [%{p: 1}, %{p: 2}, %{p: 3}] = EventBuffer.pending(config)
  end

  def delete_removes(%{config: config}) do
    Enum.each(1..3, fn idx ->
      assert :ok = EventBuffer.record(config, "d#{idx}", %{p: idx})
    end)

    assert :ok = EventBuffer.delete(config, "d2")
    pending = EventBuffer.pending(config)
    refute Enum.any?(pending, &match?(%{p: 2}, &1))
    assert Enum.any?(pending, &match?(%{p: 1}, &1))
    assert Enum.any?(pending, &match?(%{p: 3}, &1))
  end

  def first_write_wins(%{config: config}) do
    assert :ok = EventBuffer.record(config, "fw", %{p: :first})
    assert :duplicate = EventBuffer.record(config, "fw", %{p: :second})
    assert [%{p: :first}] = EventBuffer.pending(config)
  end

  def ttl_expiry(%{config: config}) do
    ttl_assert(fn ->
      assert :ok = EventBuffer.record(config, "ttl", %{p: :alive})
      assert EventBuffer.seen?(config, "ttl")
    end)

    ttl_assert(fn ->
      refute EventBuffer.seen?(config, "ttl")
      assert [] = EventBuffer.pending(config)
    end)

    assert :ok = EventBuffer.record(config, "ttl", %{p: :again})

    ttl_assert(fn ->
      assert EventBuffer.seen?(config, "ttl")
    end)
  end

  def ttl_refresh(%{config: config}) do
    assert :ok = EventBuffer.record(config, "refresh", %{p: :once})
    Process.sleep(50)
    assert :duplicate = EventBuffer.record(config, "refresh", %{p: :once})

    ttl_assert(fn ->
      assert EventBuffer.seen?(config, "refresh")
    end)

    ttl_assert(fn ->
      refute EventBuffer.seen?(config, "refresh")
    end)
  end

  def isolation(%{config: config}) do
    other =
      SlackBot.Config.build!(
        app_token: "xapp-buffer",
        bot_token: "xoxb-buffer",
        module: SlackBot.TestHandler,
        instance_name: SlackBot.TestRedis.unique_instance("Isolation"),
        event_buffer: {:ets, [table: SlackBot.EventBufferConformance.Runner.unique_ets_table()]}
      )

    start_supervised!(SlackBot.EventBuffer.child_spec(other))

    assert :ok = EventBuffer.record(config, "iso", %{p: :one})
    refute EventBuffer.seen?(other, "iso")
    assert [] = EventBuffer.pending(other)
  end

  def concurrent_race(%{config: config}) do
    parent = self()

    results =
      1..10
      |> Enum.map(fn _ ->
        Task.async(fn ->
          res = EventBuffer.record(config, "race", %{p: :race})
          send(parent, res)
          res
        end)
      end)
      |> Enum.map(&Task.await(&1, 1_000))

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == :duplicate)) == 9
  end

  defp ttl_assert(fun, timeout_ms \\ 400) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_ttl_assert(fun, deadline)
  end

  defp do_ttl_assert(fun, deadline) do
    fun.()
  rescue
    error ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_ttl_assert(fun, deadline)
      else
        reraise error, __STACKTRACE__
      end
  end
end
