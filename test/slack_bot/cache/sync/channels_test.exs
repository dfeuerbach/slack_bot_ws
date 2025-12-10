defmodule SlackBot.Cache.Sync.ChannelsTest do
  use ExUnit.Case, async: false

  alias SlackBot.Cache
  alias SlackBot.Cache.Sync.Channels
  alias SlackBot.ConfigServer

  defmodule HTTPStub do
    alias SlackBot.Config

    def post(%Config{assigns: %{http_agent: agent}}, "users.conversations", _body) do
      Agent.get_and_update(agent, fn
        [] ->
          {ok_page([], ""), []}

        [{:page, channels, next_cursor} | rest] ->
          {ok_page(channels, next_cursor), rest}

        [{:rate_limited, secs} | rest] ->
          {{:error, {:rate_limited, secs}}, rest}

        [{:error, reason} | rest] ->
          {{:error, reason}, rest}
      end)
    end

    def post(_config, "auth.test", _body), do: {:ok, %{"user_id" => "UBOT"}}
    def post(_config, _method, _body), do: {:ok, %{"ok" => true}}

    defp ok_page(channels, next_cursor) do
      {:ok, %{"channels" => channels, "response_metadata" => %{"next_cursor" => next_cursor}}}
    end
  end

  describe "SlackBot.Cache.Sync.Channels" do
    test "resumes channel sync after rate limiting and preserves cache state" do
      env =
        start_channel_sync_env(
          [
            {:rate_limited, 1},
            {:page, [channel("C1")], "next"},
            {:page, [channel("C2")], ""}
          ],
          interval_ms: 200
        )

      wait_until(fn ->
        match?(%{pending_sync: %{bot_user_id: "UBOT", cursor: nil, count: 0}}, state(env))
      end)

      send(env.server, :sync)

      wait_until(fn -> Cache.channels(env.config) |> Enum.sort() == ["C1", "C2"] end)
      assert state(env).pending_sync == nil

      meta = Cache.metadata(env.config) |> Map.get("channels_by_id", %{})
      assert Map.keys(meta) |> Enum.sort() == ["C1", "C2"]
    end

    test "persists merged channels across pages" do
      env =
        start_channel_sync_env(
          [
            {:page, [channel("C10")], "next"},
            {:page, [channel("C11")], ""}
          ],
          interval_ms: 200
        )

      wait_until(fn -> Cache.channels(env.config) |> Enum.sort() == ["C10", "C11"] end)

      meta = Cache.metadata(env.config) |> Map.get("channels_by_id", %{})
      assert Map.keys(meta) |> Enum.sort() == ["C10", "C11"]
    end

    test "honors cache_sync page_limit when fetching channels" do
      env =
        start_channel_sync_env(
          [
            {:page, [channel("C20")], "next"},
            {:page, [channel("C21")], ""}
          ],
          page_limit: 1,
          interval_ms: 5_000
        )

      wait_until(fn -> Cache.channels(env.config) == ["C20"] end)

      assert state(env).pending_sync == nil
      assert Agent.get(env.agent, & &1) == [{:page, [channel("C21")], ""}]
    end
  end

  defp start_channel_sync_env(responses, cache_opts) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    config_name = :"channel_sync_config_#{System.unique_integer([:positive])}"
    instance = Module.concat(__MODULE__, :"Instance#{System.unique_integer([:positive])}")
    server_name = :"channel_sync_server_#{System.unique_integer([:positive])}"

    cache_sync_opts =
      Keyword.merge(
        [
          enabled: true,
          kinds: [:channels],
          interval_ms: 50,
          users_conversations_opts: %{}
        ],
        cache_opts
      )

    config_opts = [
      app_token: "xapp-channel-sync",
      bot_token: "xoxb-channel-sync",
      module: SlackBot.TestHandler,
      http_client: HTTPStub,
      instance_name: instance,
      assigns: %{bot_user_id: "UBOT", http_agent: agent},
      cache_sync: cache_sync_opts
    ]

    {:ok, _} = start_supervised({ConfigServer, name: config_name, config: config_opts})
    config = ConfigServer.config(config_name)

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    start_supervised!(SlackBot.RateLimiter.child_spec(config))
    {:ok, _pid} = start_supervised({Channels, name: server_name, config_server: config_name})

    on_exit(fn ->
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    %{config: config, server: server_name, agent: agent}
  end

  defp channel(id) do
    %{
      "id" => id,
      "name" => id,
      "topic" => %{},
      "purpose" => %{}
    }
  end

  defp state(env), do: :sys.get_state(env.server)

  defp wait_until(fun, attempts \\ 40)
  defp wait_until(_fun, 0), do: flunk("condition did not become true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end
end
