defmodule SlackBot.Cache.Sync.UsersTest do
  use ExUnit.Case, async: false

  alias SlackBot.Cache
  alias SlackBot.Cache.Sync.Users
  alias SlackBot.ConfigServer

  defmodule HTTPStub do
    alias SlackBot.Config

    def post(%Config{assigns: %{http_agent: agent, test_pid: test_pid}}, "users.list", _body) do
      Agent.get_and_update(agent, fn
        [] ->
          {ok_page([], ""), []}

        [{:page, users, next_cursor} | rest] ->
          send(test_pid, {:users_list_page, next_cursor})
          {ok_page(users, next_cursor), rest}

        [{:rate_limited, secs} | rest] ->
          send(test_pid, {:users_list_rate_limited, secs})
          {{:error, {:rate_limited, secs}}, rest}

        [{:error, reason} | rest] ->
          {{:error, reason}, rest}
      end)
    end

    def post(_config, _method, _body), do: {:ok, %{"ok" => true}}

    defp ok_page(users, next_cursor) do
      {:ok, %{"members" => users, "response_metadata" => %{"next_cursor" => next_cursor}}}
    end
  end

  test "does not block the GenServer when rate limited; resumes later" do
    {:ok, agent} =
      Agent.start_link(fn ->
        [
          {:page, [user("U1")], "next"},
          {:rate_limited, 1},
          {:page, [user("U2")], ""}
        ]
      end)

    on_exit(fn ->
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    config_name = :"user_sync_config_#{System.unique_integer([:positive])}"
    instance = Module.concat(__MODULE__, :"Instance#{System.unique_integer([:positive])}")
    server_name = :"user_sync_server_#{System.unique_integer([:positive])}"

    config_opts = [
      app_token: "xapp-user-sync",
      bot_token: "xoxb-user-sync",
      module: SlackBot.TestHandler,
      http_client: HTTPStub,
      instance_name: instance,
      assigns: %{http_agent: agent, test_pid: self()},
      cache_sync: [
        enabled: true,
        kinds: [:users],
        interval_ms: 5_000,
        include_presence: false,
        users_conversations_opts: %{}
      ]
    ]

    {:ok, _} = start_supervised({ConfigServer, name: config_name, config: config_opts})
    config = ConfigServer.config(config_name)

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    start_supervised!(SlackBot.RateLimiter.child_spec(config))

    {:ok, _pid} = start_supervised({Users, name: server_name, config_server: config_name})

    assert_receive {:users_list_page, "next"}, 500
    assert_receive {:users_list_rate_limited, 1}, 500

    # Wait briefly for the GenServer to store the pending cursor after observing rate limit.
    assert wait_until(fn ->
             match?(%{pending_sync: %{cursor: "next", count: 1}}, :sys.get_state(server_name))
           end)

    # Old behavior slept inside the GenServer (unresponsive for ~1s). After hitting rate limit,
    # the new behavior should remain responsive within a small bound.
    assert %Task{} =
             task =
             Task.async(fn ->
               :sys.get_state(server_name)
             end)

    assert Task.yield(task, 300)
    Task.shutdown(task, :brutal_kill)

    # Only the first page has been cached so far.
    assert Map.keys(Cache.users(config)) |> Enum.sort() == ["U1"]

    # After the retry-after delay, the sync should resume and complete.
    assert eventually(fn ->
             Map.keys(Cache.users(config)) |> Enum.sort() == ["U1", "U2"]
           end)
  end

  defp user(id) do
    %{"id" => id, "name" => id, "profile" => %{"email" => "#{id}@example.com"}}
  end

  defp wait_until(fun, timeout_ms \\ 400)

  defp wait_until(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      true
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      if remaining == 0 do
        false
      else
        Process.sleep(min(20, remaining))
        do_wait_until(fun, deadline)
      end
    end
  end

  defp eventually(fun, attempts \\ 60)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end
end
