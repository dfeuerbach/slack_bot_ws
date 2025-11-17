defmodule SlackBot.Cache.MutationQueue do
  @moduledoc false
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    provider = Keyword.fetch!(opts, :provider)
    GenServer.start_link(__MODULE__, provider, name: name)
  end

  @impl true
  def init(provider) do
    {:ok, %{provider: provider}}
  end

  @impl true
  def handle_call({:mutate, op}, _from, %{provider: provider} = state) do
    GenServer.call(provider, {:mutate, op})
    {:reply, :ok, state}
  end
end
