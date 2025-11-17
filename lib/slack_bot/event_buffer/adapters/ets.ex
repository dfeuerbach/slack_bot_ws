defmodule SlackBot.EventBuffer.Adapters.ETS do
  @moduledoc """
  ETS-backed adapter storing envelopes for dedupe/replay.
  """

  @behaviour SlackBot.EventBuffer.Adapter

  @impl true
  def init(opts) do
    table =
      :ets.new(
        Keyword.get(opts, :table, :slackbot_event_buffer),
        [:set, :private, read_concurrency: true]
      )

    ttl_ms = Keyword.get(opts, :ttl_ms, 5 * 60_000)

    {:ok, %{table: table, ttl_ms: ttl_ms}}
  end

  @impl true
  def record(state, key, payload) do
    clean_expired(state)
    :ets.insert(state.table, {key, %{payload: payload, recorded_at: now_ms()}})
    {:ok, state}
  end

  @impl true
  def delete(state, key) do
    :ets.delete(state.table, key)
    {:ok, state}
  end

  @impl true
  def seen?(state, key) do
    {value, new_state} =
      case :ets.lookup(state.table, key) do
        [{^key, _}] -> {true, state}
        [] -> {false, state}
      end

    {value, new_state}
  end

  @impl true
  def pending(state) do
    clean_expired(state)

    entries =
      :ets.tab2list(state.table)
      |> Enum.map(fn {_key, %{payload: payload}} -> payload end)

    {entries, state}
  end

  defp clean_expired(%{ttl_ms: ttl, table: table} = state) when is_integer(ttl) and ttl > 0 do
    cutoff = now_ms() - ttl

    :ets.select_delete(
      table,
      [
        {{:"$1", %{recorded_at: :"$2"}}, [{:<, :"$2", cutoff}], [true]}
      ]
    )

    state
  end

  defp clean_expired(state), do: state

  defp now_ms, do: System.monotonic_time(:millisecond)
end
