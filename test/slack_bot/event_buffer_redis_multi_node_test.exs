defmodule SlackBot.EventBufferRedisMultiNodeTest do
  use ExUnit.Case, async: true

  alias SlackBot.EventBuffer.Server
  alias SlackBot.TestRedis

  @ttl 500

  setup do
    TestRedis.ensure!()

    namespace = "slackbot:event_buffer:redis_multi:#{System.unique_integer([:positive])}"
    instance = SlackBot.TestRedis.unique_instance("RedisMulti")
    redis_opts = TestRedis.redis_start_opts()

    adapter_opts = [
      redis: redis_opts,
      namespace: namespace,
      ttl_ms: @ttl,
      instance_name: instance
    ]

    config_a =
      SlackBot.Config.build!(
        app_token: "xapp-buffer",
        bot_token: "xoxb-buffer",
        module: SlackBot.TestHandler,
        instance_name: instance,
        event_buffer: {:adapter, SlackBot.EventBuffer.Adapters.Redis, adapter_opts}
      )

    config_b =
      SlackBot.Config.build!(
        app_token: "xapp-buffer",
        bot_token: "xoxb-buffer",
        module: SlackBot.TestHandler,
        instance_name: instance,
        event_buffer: {:adapter, SlackBot.EventBuffer.Adapters.Redis, adapter_opts}
      )

    {:ok, server_a} =
      Server.start_link(
        name: :"#{instance}.ServerA",
        adapter: SlackBot.EventBuffer.Adapters.Redis,
        adapter_opts: adapter_opts
      )

    {:ok, server_b} =
      Server.start_link(
        name: :"#{instance}.ServerB",
        adapter: SlackBot.EventBuffer.Adapters.Redis,
        adapter_opts: adapter_opts
      )

    on_exit(fn ->
      maybe_stop(server_a)
      maybe_stop(server_b)
      cleanup_redis(namespace, instance)
    end)

    %{
      config_a: config_a,
      config_b: config_b,
      server_a: server_a,
      server_b: server_b
    }
  end

  test "records once and dedupes across servers", %{
    config_a: _config_a,
    config_b: _config_b,
    server_a: server_a,
    server_b: server_b
  } do
    assert :ok = GenServer.call(server_a, {:record, "k1", %{p: :shared}})
    assert :duplicate = GenServer.call(server_b, {:record, "k1", %{p: :shared}})

    assert GenServer.call(server_a, {:seen?, "k1"})
    assert GenServer.call(server_b, {:seen?, "k1"})
  end

  test "pending is visible across servers", %{
    config_a: _config_a,
    config_b: _config_b,
    server_a: server_a,
    server_b: server_b
  } do
    assert :ok = GenServer.call(server_a, {:record, "k2", %{p: :shared}})
    assert [%{p: :shared}] = GenServer.call(server_b, :pending)
  end

  test "delete on one server removes visibility on the other", %{
    config_a: _config_a,
    config_b: _config_b,
    server_a: server_a,
    server_b: server_b
  } do
    assert :ok = GenServer.call(server_a, {:record, "k3", %{p: :shared}})
    assert :ok = GenServer.call(server_a, {:delete, "k3"})
    Process.sleep(50)
    refute GenServer.call(server_b, {:seen?, "k3"})
  end

  defp cleanup_redis(namespace, instance) do
    conn_opts =
      Keyword.put(
        TestRedis.redis_start_opts(),
        :name,
        SlackBot.TestRedis.unique_instance("cleanup")
      )

    case Redix.start_link(conn_opts) do
      {:ok, conn} ->
        pattern = "#{namespace}:#{instance}:*"
        scan_delete(conn, pattern)
        Redix.command(conn, ["DEL", "#{namespace}:#{instance}:pending"])
        Redix.stop(conn)

      _ ->
        :ok
    end
  end

  defp scan_delete(conn, pattern), do: do_scan_delete(conn, "0", pattern)

  defp do_scan_delete(conn, cursor, pattern) do
    case Redix.command(conn, ["SCAN", cursor, "MATCH", pattern, "COUNT", "100"]) do
      {:ok, ["0", []]} ->
        :ok

      {:ok, [next, keys]} ->
        if keys != [] do
          _ = Redix.command(conn, ["DEL" | keys])
        end

        do_scan_delete(conn, next, pattern)

      _ ->
        :ok
    end
  end

  defp maybe_stop(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        _, _ -> :ok
      end
    end
  end
end
