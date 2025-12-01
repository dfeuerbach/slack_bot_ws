defmodule SlackBot.RateLimiterTest do
  use ExUnit.Case, async: true

  alias SlackBot.Config
  alias SlackBot.RateLimiter
  alias SlackBot.RateLimiter.Adapters.ETS

  defp base_config(opts) do
    struct!(
      Config,
      %{
        app_token: "xapp-rate",
        bot_token: "xoxb-rate",
        module: SlackBot.TestHandler,
        instance_name: Keyword.get(opts, :instance_name, __MODULE__.Instance),
        telemetry_prefix: Keyword.get(opts, :telemetry_prefix, [:slackbot]),
        rate_limiter: Keyword.get(opts, :rate_limiter, :none)
      }
    )
  end

  describe "around_request/4" do
    test "bypasses rate limiter when disabled" do
      config = base_config(rate_limiter: :none)

      parent = self()

      result =
        RateLimiter.around_request(config, "chat.postMessage", %{"channel" => "C1"}, fn ->
          send(parent, :executed)
          :ok
        end)

      assert result == :ok
      assert_receive :executed
    end

    test "serializes requests per channel using ETS adapter" do
      instance = __MODULE__.ChannelInstance

      config =
        base_config(
          instance_name: instance,
          rate_limiter: {:adapter, ETS, table: :rate_limiter_test_table}
        )

      start_supervised!(RateLimiter.child_spec(config))

      parent = self()

      fun = fn label ->
        send(parent, {:start, label, self()})

        receive do
          {:continue, ^label} -> :ok
        end
      end

      task1 =
        Task.async(fn ->
          RateLimiter.around_request(
            config,
            "chat.postMessage",
            %{"channel" => "C-chan"},
            fn -> fun.(:first) end
          )
        end)

      task2 =
        Task.async(fn ->
          RateLimiter.around_request(
            config,
            "chat.postMessage",
            %{"channel" => "C-chan"},
            fn -> fun.(:second) end
          )
        end)

      # Exactly one request should start before the first is allowed to finish.
      assert_receive {:start, label1, pid1}
      refute_receive {:start, _label, _pid}, 50

      send(pid1, {:continue, label1})

      # After the first completes, the second request should be admitted.
      assert_receive {:start, label2, pid2}
      send(pid2, {:continue, label2})

      assert :ok = Task.await(task1)
      assert :ok = Task.await(task2)
    end

    test "detects channel keys when payload uses atoms" do
      instance = __MODULE__.AtomChannelInstance

      config =
        base_config(
          instance_name: instance,
          rate_limiter: {:adapter, ETS, table: :rate_limiter_atom_table}
        )

      start_supervised!(RateLimiter.child_spec(config))

      parent = self()

      fun = fn label ->
        send(parent, {:start, label, self()})

        receive do
          {:continue, ^label} -> :ok
        end
      end

      task1 =
        Task.async(fn ->
          RateLimiter.around_request(
            config,
            "chat.postMessage",
            %{channel: "C-atom"},
            fn -> fun.(:one) end
          )
        end)

      task2 =
        Task.async(fn ->
          RateLimiter.around_request(
            config,
            "chat.postMessage",
            %{channel: "C-atom"},
            fn -> fun.(:two) end
          )
        end)

      assert_receive {:start, label1, pid1}
      refute_receive {:start, _label, _pid}, 50

      send(pid1, {:continue, label1})

      assert_receive {:start, label2, pid2}
      send(pid2, {:continue, label2})

      assert :ok = Task.await(task1)
      assert :ok = Task.await(task2)
    end
  end

  describe "telemetry" do
    test "emits decision and rate_limited events on 429 result" do
      instance = __MODULE__.TelemetryInstance

      config =
        base_config(
          instance_name: instance,
          telemetry_prefix: [:slackbot],
          rate_limiter: {:adapter, ETS, table: :rate_limiter_telemetry_table}
        )

      start_supervised!(RateLimiter.child_spec(config))

      parent = self()

      decision_handler = {:rate_decision, make_ref()}
      rate_limited_handler = {:api_rate_limited, make_ref()}

      :telemetry.attach(
        decision_handler,
        [:slackbot, :rate_limiter, :decision],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        rate_limited_handler,
        [:slackbot, :api, :rate_limited],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(decision_handler)
        :telemetry.detach(rate_limited_handler)
      end)

      result =
        RateLimiter.around_request(
          config,
          "chat.postMessage",
          %{"channel" => "C-telemetry"},
          fn -> {:error, {:rate_limited, 2}} end
        )

      assert {:error, {:rate_limited, 2}} = result

      assert_receive {:telemetry, [:slackbot, :rate_limiter, :decision],
                      %{queue_length: 0, in_flight: 1},
                      %{
                        key: {:channel, "C-telemetry"},
                        method: "chat.postMessage",
                        decision: :allow
                      }}

      assert_receive {:telemetry, [:slackbot, :api, :rate_limited],
                      %{retry_after_ms: 2000, observed_at_ms: _},
                      %{method: "chat.postMessage", key: {:channel, "C-telemetry"}}}
    end

    test "emits blocked and drain telemetry for retry-after windows" do
      instance = __MODULE__.BlockedInstance

      config =
        base_config(
          instance_name: instance,
          telemetry_prefix: [:slackbot],
          rate_limiter: {:adapter, ETS, table: :rate_limiter_blocked_table}
        )

      start_supervised!(RateLimiter.child_spec(config))

      parent = self()
      blocked_handler = {:rate_blocked, make_ref()}
      drain_handler = {:rate_drain, make_ref()}

      :telemetry.attach(
        blocked_handler,
        [:slackbot, :rate_limiter, :blocked],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        drain_handler,
        [:slackbot, :rate_limiter, :drain],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(blocked_handler)
        :telemetry.detach(drain_handler)
      end)

      # First call records a retry-after window.
      RateLimiter.around_request(
        config,
        "chat.postMessage",
        %{"channel" => "C-block"},
        fn -> {:error, {:rate_limited, 1}} end
      )

      task =
        Task.async(fn ->
          RateLimiter.around_request(
            config,
            "chat.postMessage",
            %{"channel" => "C-block"},
            fn -> :ok end
          )
        end)

      assert_receive {:telemetry, [:slackbot, :rate_limiter, :blocked], %{delay_ms: delay_ms},
                      %{key: {:channel, "C-block"}, method: "chat.postMessage"}}

      assert_in_delta(delay_ms, 1000, 200)

      assert_receive {:telemetry, [:slackbot, :rate_limiter, :drain],
                      %{drained: 1, delay_ms: drain_delay},
                      %{key: {:channel, "C-block"}, reason: :retry_after}},
                     1_500

      assert_in_delta(drain_delay, 1000, 200)

      assert :ok = Task.await(task, 2_000)
    end
  end
end
