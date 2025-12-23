defmodule SlackBot.EventBuffer.Adapters.ETS do
  @moduledoc false

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

    entry = %{payload: payload, recorded_at: now_ms()}

    case :ets.insert_new(state.table, {key, entry}) do
      true ->
        {:ok, state}

      false ->
        case :ets.lookup(state.table, key) do
          [{^key, %{payload: existing_payload}}] ->
            :ets.insert(state.table, {key, %{payload: existing_payload, recorded_at: now_ms()}})
            {:duplicate, state}

          [] ->
            :ets.insert(state.table, {key, entry})
            {:ok, state}
        end
    end
  end

  @impl true
  def delete(state, key) do
    :ets.delete(state.table, key)
    {:ok, state}
  end

  @impl true
  def seen?(state, key) do
    case :ets.lookup(state.table, key) do
      [{^key, %{recorded_at: recorded_at}}] ->
        if expired?(state, recorded_at) do
          :ets.delete(state.table, key)
          {false, state}
        else
          {true, state}
        end

      [] ->
        {false, state}
    end
  end

  @impl true
  def pending(state) do
    clean_expired(state)

    entries =
      state.table
      |> :ets.tab2list()
      |> Enum.map(fn {_key, %{payload: payload, recorded_at: recorded_at}} ->
        {recorded_at, payload}
      end)
      |> Enum.sort_by(fn {recorded_at, _payload} -> recorded_at end)
      |> Enum.map(fn {_recorded_at, payload} -> payload end)

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

  defp expired?(%{ttl_ms: ttl}, recorded_at) when is_integer(ttl) and ttl > 0 do
    now_ms() - recorded_at > ttl
  end

  defp expired?(_state, _recorded_at), do: false

  defp now_ms, do: System.monotonic_time(:millisecond)
end
