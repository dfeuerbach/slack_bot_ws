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
    {:reply, state.users, state}
  end

  def handle_call(:metadata, _from, state) do
    {:reply, state.metadata, state}
  end

  @impl true
  def handle_call({:mutate, op}, _from, state) do
    {:reply, :ok, apply_op(state, op)}
  end

  @impl true
  def handle_cast({:mutate, op}, state) do
    {:noreply, apply_op(state, op)}
  end

  defp apply_op(state, {:join_channel, channel}) do
    %{state | channels: MapSet.put(state.channels, channel)}
  end

  defp apply_op(state, {:leave_channel, channel}) do
    %{state | channels: MapSet.delete(state.channels, channel)}
  end

  defp apply_op(state, {:put_user, %{"id" => id} = user}) do
    %{state | users: Map.put(state.users, id, user)}
  end

  defp apply_op(state, {:put_user, _}), do: state

  defp apply_op(state, {:put_metadata, metadata}) do
    %{state | metadata: Map.merge(state.metadata, metadata)}
  end

  defp apply_op(state, _), do: state
end
