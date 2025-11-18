defmodule SlackBot.Diagnostics.Server do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    buffer_size = Keyword.get(opts, :buffer_size, 200)
    enabled = Keyword.get(opts, :enabled, false)
    GenServer.start_link(__MODULE__, %{buffer_size: buffer_size, enabled: enabled}, name: name)
  end

  @impl true
  def init(state) do
    {:ok, Map.merge(state, %{buffer: :queue.new()})}
  end

  @impl true
  def handle_cast({:record, _entry}, %{enabled: false} = state), do: {:noreply, state}

  def handle_cast({:record, entry}, state) do
    new_buffer =
      entry
      |> :queue.in(state.buffer)
      |> trim(state.buffer_size)

    {:noreply, %{state | buffer: new_buffer}}
  end

  def handle_cast(:clear, state) do
    {:noreply, %{state | buffer: :queue.new()}}
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    entries =
      state.buffer
      |> :queue.to_list()
      |> filter(opts)

    {:reply, entries, state}
  end

  def handle_call({:replay_source, opts}, _from, state) do
    entries =
      state.buffer
      |> :queue.to_list()
      |> filter(opts)

    {:reply, entries, state}
  end

  defp trim(queue, max_size) do
    cond do
      max_size <= 0 ->
        :queue.new()

      :queue.len(queue) > max_size ->
        {_dropped, new_queue} = :queue.out(queue)
        trim(new_queue, max_size)

      true ->
        queue
    end
  end

  defp filter(entries, opts) do
    direction = Keyword.get(opts, :direction, :both)
    limit = Keyword.get(opts, :limit, length(entries))
    types = Keyword.get(opts, :types, :all)
    order = Keyword.get(opts, :order, :newest_first)

    entries
    |> maybe_reverse(order)
    |> Enum.filter(&match_direction?(&1, direction))
    |> Enum.filter(&match_type?(&1, types))
    |> Enum.take(limit)
  end

  defp maybe_reverse(list, :oldest_first), do: list
  defp maybe_reverse(list, _), do: Enum.reverse(list)

  defp match_direction?(_entry, :both), do: true
  defp match_direction?(%{direction: dir}, dir), do: true
  defp match_direction?(_, _), do: false

  defp match_type?(_entry, :all), do: true
  defp match_type?(%{type: type}, types) when is_list(types), do: type in types
  defp match_type?(%{type: type}, type), do: true
  defp match_type?(_, _), do: false
end
