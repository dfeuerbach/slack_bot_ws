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
      |> Map.put(:telemetry_prefix, [:slackbot])

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

  test "emits telemetry for decisions, suspensions, and resumes", %{config: config} do
    set_tiers(%{"users.list" => %{max_calls: 1, window_ms: 60, scope: :workspace}})

    parent = self()
    decision_handler = {:tier_decision, make_ref()}
    suspend_handler = {:tier_suspend, make_ref()}
    resume_handler = {:tier_resume, make_ref()}

    :telemetry.attach(
      decision_handler,
      [:slackbot, :tier_limiter, :decision],
      fn event, measurements, metadata, _ ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    :telemetry.attach(
      suspend_handler,
      [:slackbot, :tier_limiter, :suspend],
      fn event, measurements, metadata, _ ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    :telemetry.attach(
      resume_handler,
      [:slackbot, :tier_limiter, :resume],
      fn event, measurements, metadata, _ ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(decision_handler)
      :telemetry.detach(suspend_handler)
      :telemetry.detach(resume_handler)
    end)

    assert :ok = TierLimiter.acquire(config, "users.list", %{})

    assert_receive {:telemetry, [:slackbot, :tier_limiter, :decision],
                    %{tokens: tokens, queue_length: 0},
                    %{method: "users.list", decision: :allow}}

    assert is_number(tokens)

    TierLimiter.suspend(config, "users.list", %{}, 50)

    assert_receive {:telemetry, [:slackbot, :tier_limiter, :suspend], %{delay_ms: delay},
                    %{method: "users.list", scope_key: scope_key}}

    assert scope_key == config.instance_name

    assert delay >= 50

    task =
      Task.async(fn ->
        TierLimiter.acquire(config, "users.list", %{})
      end)

    refute Task.yield(task, 20)

    assert_receive {:telemetry, [:slackbot, :tier_limiter, :resume],
                    %{tokens: _resume_tokens, queue_length: _},
                    %{method: "users.list", scope_key: resume_scope_key}}, 200

    assert resume_scope_key == config.instance_name

    assert :ok = Task.await(task, 200)
  end

  defp set_tiers(tiers) when is_map(tiers) do
    Application.put_env(:slack_bot_ws, SlackBot.TierRegistry, tiers: tiers)
  end
end
