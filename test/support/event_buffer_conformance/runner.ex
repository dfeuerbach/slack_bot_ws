defmodule SlackBot.EventBufferConformance.Runner do
  @moduledoc false

  import ExUnit.Callbacks, only: [start_supervised!: 1]
  alias SlackBot.TestRedis

  @type backend :: :ets | :redis

  @spec start!(backend(), keyword()) :: %{
          config: SlackBot.Config.t(),
          cleanup: (-> :ok),
          meta: map()
        }
  def start!(:ets, opts) do
    instance = unique_instance(:ets)
    table = Keyword.get(opts, :table, unique_ets_table())
    ttl_ms = Keyword.get(opts, :ttl_ms, 200)

    config =
      SlackBot.Config.build!(
        app_token: "xapp-buffer",
        bot_token: "xoxb-buffer",
        module: SlackBot.TestHandler,
        instance_name: instance,
        event_buffer: {:ets, [table: table, ttl_ms: ttl_ms]}
      )

    start_child!(config)

    %{
      config: config,
      cleanup: fn -> :ok end,
      meta: %{table: table, ttl_ms: ttl_ms}
    }
  end

  def start!(:redis, opts) do
    instance = unique_instance(:redis)
    ttl_ms = Keyword.get(opts, :ttl_ms, 200)
    namespace = Keyword.get(opts, :namespace, unique_namespace())

    TestRedis.ensure!()

    redis_opts =
      Keyword.merge(TestRedis.redis_start_opts(), Keyword.get(opts, :redis_opts, []))

    config =
      SlackBot.Config.build!(
        app_token: "xapp-buffer",
        bot_token: "xoxb-buffer",
        module: SlackBot.TestHandler,
        instance_name: instance,
        event_buffer:
          {:adapter, SlackBot.EventBuffer.Adapters.Redis,
           [redis: redis_opts, namespace: namespace, ttl_ms: ttl_ms]}
      )

    start_child!(config)

    %{
      config: config,
      cleanup: cleanup_redis(namespace, instance, config),
      meta: %{namespace: namespace, ttl_ms: ttl_ms}
    }
  end

  defp start_child!(config) do
    child_spec = SlackBot.EventBuffer.child_spec(config)
    start_supervised!(child_spec)
  end

  defp cleanup_redis(namespace, instance, _config) do
    fn ->
      conn_opts = Keyword.put(TestRedis.redis_start_opts(), :name, unique_instance(:cleanup))

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
  end

  defp scan_delete(conn, pattern) do
    do_scan_delete(conn, "0", pattern)
  end

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

  def unique_ets_table do
    :"event_buffer_conformance_#{System.unique_integer([:positive])}"
  end

  def unique_namespace do
    "slackbot:event_buffer:conformance:#{System.unique_integer([:positive])}"
  end

  defp unique_instance(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
