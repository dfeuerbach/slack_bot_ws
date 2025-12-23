defmodule SlackBot.EventBuffer.Server do
  @moduledoc false
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    GenServer.start_link(__MODULE__, {adapter, adapter_opts}, name: name)
  end

  @impl true
  def init({adapter, adapter_opts}) do
    {:ok, state} = adapter.init(adapter_opts)
    {:ok, %{adapter: adapter, state: state}}
  end

  @impl true
  def handle_call(
        {:record, key, payload},
        _from,
        %{adapter: adapter, state: adapter_state} = state
      ) do
    {status, new_state} = adapter.record(adapter_state, key, payload)
    {:reply, status, %{state | state: new_state}}
  end

  @impl true
  def handle_call({:delete, key}, _from, %{adapter: adapter, state: adapter_state} = state) do
    {:ok, new_state} = adapter.delete(adapter_state, key)
    {:reply, :ok, %{state | state: new_state}}
  end

  @impl true
  def handle_call({:seen?, key}, _from, %{adapter: adapter, state: adapter_state} = state) do
    {value, new_state} = adapter.seen?(adapter_state, key)
    {:reply, value, %{state | state: new_state}}
  end

  @impl true
  def handle_call(:pending, _from, %{adapter: adapter, state: adapter_state} = state) do
    {value, new_state} = adapter.pending(adapter_state)
    {:reply, value, %{state | state: new_state}}
  end
end
