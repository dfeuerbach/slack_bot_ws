defmodule SlackBot.RateLimiter.Adapters.ETS do
  @moduledoc false

  @behaviour SlackBot.RateLimiter.Adapter

  alias SlackBot.RateLimiter.Adapter

  @impl Adapter
  def init(_config, opts) do
    name = Keyword.get(opts, :table, :slackbot_rate_limiter)

    table =
      case :ets.whereis(name) do
        :undefined ->
          :ets.new(name, [:set, :named_table, :public, read_concurrency: true])

        tid ->
          tid
      end

    ttl_ms = Keyword.get(opts, :ttl_ms, 10 * 60_000)

    {:ok, %{table: table, ttl_ms: ttl_ms}}
  end

  @impl Adapter
  def blocked_until(%{table: table, ttl_ms: ttl} = state, key, now_ms) do
    cutoff = if is_integer(ttl) and ttl > 0, do: now_ms - ttl, else: 0

    blocked_until =
      case :ets.lookup(table, key) do
        [{^key, ts}] when is_integer(ts) ->
          cond do
            ts < cutoff ->
              :ets.delete(table, key)
              nil

            ts <= now_ms ->
              # window has expired; clean it up eagerly
              :ets.delete(table, key)
              nil

            true ->
              ts
          end

        _ ->
          nil
      end

    {blocked_until, state}
  end

  @impl Adapter
  def record_result(%{table: table} = state, key, now_ms, result) do
    case result do
      {:error, {:rate_limited, secs}} when is_integer(secs) and secs > 0 ->
        blocked_until = now_ms + secs * 1_000
        :ets.insert(table, {key, blocked_until})
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end
end
