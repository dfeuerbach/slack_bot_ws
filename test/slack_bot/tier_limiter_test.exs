defmodule SlackBot.TierLimiterTest do
  use ExUnit.Case, async: false

  alias SlackBot.TierLimiter

  setup do
    Application.put_env(:slack_bot_ws, SlackBot.TierRegistry,
      tiers: %{"users.list" => %{max_calls: 1, window_ms: 50, scope: :workspace}}
    )

    on_exit(fn -> Application.delete_env(:slack_bot_ws, SlackBot.TierRegistry) end)

    config =
      SlackBot.Config.build!(
        app_token: "xapp-tier",
        bot_token: "xoxb-tier",
        module: SlackBot.TestHandler,
        instance_name: __MODULE__.Bot
      )

    start_supervised!(TierLimiter.child_spec(config))

    %{config: config}
  end

  test "queues when exceeding tier budget and releases later", %{config: config} do
    set_tiers(%{"users.list" => %{max_calls: 1, window_ms: 50, scope: :workspace}})
    {:ok, spec} = SlackBot.TierRegistry.lookup("users.list")
    assert spec.max_calls == 1

    assert :ok = TierLimiter.acquire(config, "users.list", %{})

    task =
      Task.async(fn ->
        TierLimiter.acquire(config, "users.list", %{})
      end)

    refute Task.yield(task, 30)

    Process.sleep(80)

    assert :ok = Task.await(task, 100)
  end

  test "shares tokens across grouped specs", %{config: config} do
    set_tiers(%{
      "users.list" => %{max_calls: 1, window_ms: 50, scope: :workspace, group: :catalog},
      "users.conversations" => %{
        max_calls: 1,
        window_ms: 50,
        scope: :workspace,
        group: :catalog
      }
    })

    assert :ok = TierLimiter.acquire(config, "users.list", %{})

    task =
      Task.async(fn ->
        TierLimiter.acquire(config, "users.conversations", %{})
      end)

    refute Task.yield(task, 30)
    Process.sleep(80)
    assert :ok = Task.await(task, 100)
  end

  test "honors initial fill ratio", %{config: config} do
    set_tiers(%{
      "custom.method" => %{
        max_calls: 4,
        window_ms: 80,
        scope: :workspace,
        burst_ratio: 0.0,
        initial_fill_ratio: 0.25
      }
    })

    assert :ok = TierLimiter.acquire(config, "custom.method", %{})

    task =
      Task.async(fn ->
        TierLimiter.acquire(config, "custom.method", %{})
      end)

    refute Task.yield(task, 10)
    Process.sleep(50)
    assert :ok = Task.await(task, 150)
  end

  test "suspends bucket when asked", %{config: config} do
    set_tiers(%{"users.list" => %{max_calls: 1, window_ms: 50, scope: :workspace}})
    assert :ok = TierLimiter.acquire(config, "users.list", %{})

    TierLimiter.suspend(config, "users.list", %{}, 100)

    task =
      Task.async(fn ->
        TierLimiter.acquire(config, "users.list", %{})
      end)

    refute Task.yield(task, 50)
    Process.sleep(120)
    assert :ok = Task.await(task, 150)
  end

  defp set_tiers(tiers) when is_map(tiers) do
    Application.put_env(:slack_bot_ws, SlackBot.TierRegistry, tiers: tiers)
  end
end
