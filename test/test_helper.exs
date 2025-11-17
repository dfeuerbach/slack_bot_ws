ExUnit.start()

defmodule SlackBot.TestHandler do
  @moduledoc false

  def handle_event(type, payload, ctx) do
    if test_pid = ctx.assigns[:test_pid] do
      send(test_pid, {:handled, type, payload, ctx})
    end

    :ok
  end
end

defmodule SlackBot.TestHTTP do
  @moduledoc false

  def apps_connections_open(_app_token), do: {:ok, "wss://test.example/socket"}
  def post(_method, _token, body), do: {:ok, body}
end

defmodule SlackBot.TestTransport do
  @moduledoc false
  use GenServer

  def start_link(_url, opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def emit(pid, type, payload, meta \\ %{}) do
    GenServer.cast(pid, {:emit, type, payload, meta})
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
end
