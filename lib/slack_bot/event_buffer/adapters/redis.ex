defmodule SlackBot.EventBuffer.Adapters.Redis do
  @moduledoc """
  Redis-backed event buffer adapter.

  This adapter uses Redis to persist envelope dedupe metadata so multiple BEAM nodes
  can share a common view. Configuration options:

    * `:instance_name` – provided automatically; used to namespace keys.
    * `:redis` – keyword list forwarded to `Redix.start_link/1` (defaults to `[]`).
      Provide `host`, `port`, or `url` here.
    * `:conn` – alternatively pass an existing Redix connection PID to reuse pools.
    * `:namespace` – Redis key namespace (default: `"slackbot:event_buffer"`).
    * `:ttl_ms` – milliseconds before entries expire (default: 5 minutes).
    * `:redix` – (advanced) module implementing the `Redix` API, defaulting to `Redix`.
      Primarily useful for injecting a test double in unit tests.
  """

  @behaviour SlackBot.EventBuffer.Adapter
  @compile {:no_warn_undefined, Redix}

  require Logger

  @default_ttl 5 * 60_000
  @prune_window 10 * 60_000

  @impl true
  def init(opts) do
    instance = Keyword.fetch!(opts, :instance_name)
    namespace = Keyword.get(opts, :namespace, "slackbot:event_buffer")
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl)
    redix = Keyword.get(opts, :redix, Redix)

    conn =
      case Keyword.fetch(opts, :conn) do
        {:ok, pid} ->
          pid

        :error ->
          redis_opts = Keyword.get(opts, :redis, [])
          {:ok, pid} = redix.start_link(redis_opts)
          pid
      end

    state = %{
      conn: conn,
      redix: redix,
      instance: instance,
      namespace: namespace,
      ttl_ms: ttl_ms
    }

    {:ok, state}
  end

  @impl true
  def record(state, key, payload) do
    encoded = :erlang.term_to_binary(%{payload: payload, recorded_at: now_ms()})
    entry_key = entry_key(state, key)
    ttl_arg = Integer.to_string(state.ttl_ms)
    now = now_ms()

    case command(state, ["SET", entry_key, encoded, "PX", ttl_arg, "NX"]) do
      {:ok, "OK"} ->
        _ =
          pipeline(state, [
            ["ZADD", pending_key(state), now, entry_key],
            ["ZREMRANGEBYSCORE", pending_key(state), "-inf", now - state.ttl_ms]
          ])

        {:ok, state}

      {:ok, nil} ->
        _ =
          pipeline(state, [
            ["PEXPIRE", entry_key, ttl_arg],
            ["ZADD", pending_key(state), now, entry_key],
            ["ZREMRANGEBYSCORE", pending_key(state), "-inf", now - state.ttl_ms]
          ])

        {:duplicate, state}

      {:error, reason} ->
        log_error(:record, reason, state)
        {:ok, state}
    end
  end

  @impl true
  def delete(state, key) do
    entry_key = entry_key(state, key)

    case pipeline(state, [
           ["DEL", entry_key],
           ["ZREM", pending_key(state), entry_key]
         ]) do
      {:ok, _} ->
        {:ok, state}

      {:error, reason} ->
        log_error(:delete, reason, state)
        {:ok, state}
    end
  end

  @impl true
  def seen?(state, key) do
    case command(state, ["EXISTS", entry_key(state, key)]) do
      {:ok, 1} ->
        {true, state}

      {:ok, 0} ->
        {false, state}

      {:error, reason} ->
        log_error(:seen?, reason, state)
        {false, state}
    end
  end

  @impl true
  def pending(state) do
    prune_before = now_ms() - max(state.ttl_ms, @prune_window)

    case command(state, ["ZREMRANGEBYSCORE", pending_key(state), "-inf", prune_before]) do
      {:ok, _} ->
        do_pending(state)

      {:error, reason} ->
        log_error(:pending, reason, state)
        {[], state}
    end
  end

  defp entry_key(%{namespace: namespace, instance: instance}, key) do
    "#{namespace}:#{instance}:#{key}"
  end

  defp pending_key(%{namespace: namespace, instance: instance}) do
    "#{namespace}:#{instance}:pending"
  end

  defp command(state, command), do: state.redix.command(state.conn, command)

  defp pipeline(state, commands), do: state.redix.pipeline(state.conn, commands)

  defp decode(value) when is_binary(value) do
    {:ok, :erlang.binary_to_term(value)}
  rescue
    _ -> :error
  end

  defp do_pending(state) do
    state
    |> command(["ZRANGE", pending_key(state), 0, -1])
    |> handle_pending_keys(state)
  end

  defp handle_pending_keys({:ok, []}, state), do: {[], state}

  defp handle_pending_keys({:ok, keys}, state) do
    case command(state, ["MGET" | keys]) do
      {:ok, values} ->
        {build_pending_payloads(keys, values), state}

      {:error, reason} ->
        log_error(:pending, reason, state)
        {[], state}
    end
  end

  defp handle_pending_keys({:error, reason}, state) do
    log_error(:pending, reason, state)
    {[], state}
  end

  defp build_pending_payloads(keys, values) do
    keys
    |> Enum.zip(values)
    |> Enum.reduce([], fn
      {_key, nil}, acc ->
        acc

      {_key, value}, acc ->
        case decode(value) do
          {:ok, %{payload: payload}} -> [payload | acc]
          _ -> acc
        end
    end)
    |> Enum.reverse()
  end

  defp log_error(operation, reason, %{instance: instance}) do
    Logger.warning(
      "[SlackBot] Redis event buffer error operation=#{inspect(operation)} instance=#{inspect(instance)} reason=#{inspect(reason)}"
    )
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
