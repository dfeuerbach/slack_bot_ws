defmodule SlackBot.Cache.Janitor do
  @moduledoc false

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    provider = Keyword.fetch!(opts, :provider)
    interval_ms = Keyword.fetch!(opts, :interval_ms)

    state = %{provider: provider, interval_ms: interval_ms}
    schedule_cleanup(interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup, %{provider: provider, interval_ms: interval_ms} = state) do
    now = System.monotonic_time(:millisecond)
    GenServer.cast(provider, {:cleanup, now})
    schedule_cleanup(interval_ms)
    {:noreply, state}
  end

  defp schedule_cleanup(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :cleanup, interval_ms)
  end
end
