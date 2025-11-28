defmodule SlackBot.Cache.Provider do
  @moduledoc false
  use GenServer

  @initial_state %{
    channels: MapSet.new(),
    users: %{},
    metadata: %{}
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @impl true
  def init(_) do
    {:ok, @initial_state}
  end

  @impl true
  def handle_call(:channels, _from, state) do
    {:reply, MapSet.to_list(state.channels), state}
  end

  def handle_call(:users, _from, state) do
    now = now_ms()
    {users, new_state} = prune_expired_users(state, now)

    plain =
      users
      |> Enum.reduce(%{}, fn {id, %{data: data}}, acc -> Map.put(acc, id, data) end)

    {:reply, plain, new_state}
  end

  def handle_call(:metadata, _from, state) do
    {:reply, state.metadata, state}
  end

  def handle_call({:user_entry, user_id}, _from, state) do
    now = now_ms()
    {users, new_state} = prune_expired_users(state, now)

    reply =
      case Map.fetch(users, user_id) do
        {:ok, entry} -> {:ok, entry}
        :error -> :not_found
      end

    {:reply, reply, new_state}
  end

  @impl true
  def handle_call({:mutate, op}, _from, state) do
    {:reply, :ok, apply_op(state, op)}
  end

  @impl true
  def handle_cast({:mutate, op}, state) do
    {:noreply, apply_op(state, op)}
  end

  @impl true
  def handle_cast({:cleanup, now}, state) do
    {_, new_state} = prune_expired_users(state, now)
    {:noreply, new_state}
  end

  defp apply_op(state, {:join_channel, channel}) do
    %{state | channels: MapSet.put(state.channels, channel)}
  end

  defp apply_op(state, {:leave_channel, channel}) do
    %{state | channels: MapSet.delete(state.channels, channel)}
  end

  defp apply_op(state, {:put_user, %{"id" => id} = user, expires_at}) do
    entry = %{data: user, expires_at: expires_at}
    %{state | users: Map.put(state.users, id, entry)}
  end

  defp apply_op(state, {:put_user, _user, _expires_at}), do: state

  defp apply_op(state, {:drop_user, user_id}) do
    %{state | users: Map.delete(state.users, user_id)}
  end

  defp apply_op(state, {:put_metadata, metadata}) do
    %{state | metadata: Map.merge(state.metadata, metadata)}
  end

  defp apply_op(state, _), do: state

  defp prune_expired_users(state, now) do
    remaining =
      Enum.reduce(state.users, %{}, fn
        {id, %{expires_at: expires_at} = entry}, acc ->
          if expires_at > now do
            Map.put(acc, id, entry)
          else
            acc
          end
      end)

    new_state = %{state | users: remaining}
    {remaining, new_state}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
