defmodule SlackBot.TestTransport do
  @moduledoc """
  Test transport for simulating Slack Socket Mode traffic without a live connection.

  ## Options

    * `:manager` – the connection manager PID (required).
    * `:notify` – optional PID to receive `{:test_transport, pid}` when the transport starts.
  """

  use GenServer

  def start_link(_url, opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Emits an event with the given `type`, `payload`, and optional `meta` map.
  """
  def emit(pid, type, payload, meta \\ %{}) do
    GenServer.cast(pid, {:emit, type, payload, meta})
  end

  @doc """
  Simulates Slack sending a disconnect frame.
  """
  def disconnect(pid, payload \\ %{}) do
    GenServer.cast(pid, {:disconnect, payload})
  end

  @impl true
  def init(opts) do
    manager = Keyword.fetch!(opts, :manager)
    notify = Keyword.get(opts, :notify)

    if notify, do: send(notify, {:test_transport, self()})
    send(manager, {:slackbot, :connected, self()})

    {:ok, %{manager: manager}}
  end

  @impl true
  def handle_cast({:emit, type, payload, meta}, state) do
    send(state.manager, {:slackbot, :event, type, payload, meta})
    {:noreply, state}
  end

  def handle_cast({:disconnect, payload}, state) do
    send(state.manager, {:slackbot, :disconnect, payload})
    {:noreply, state}
  end
end
