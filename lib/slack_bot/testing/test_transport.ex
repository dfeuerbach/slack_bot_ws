defmodule SlackBot.TestTransport do
  @moduledoc """
  Stub WebSocket transport for testing event handlers without Socket Mode.

  Use this to simulate Slack sending events to your bot—perfect for testing
  handlers in isolation without depending on live Slack connections.

  ## Configuration

  Set this as your transport in test config:

      # config/test.exs
      config :my_app, MyApp.SlackBot,
        transport: SlackBot.TestTransport,
        http_client: SlackBot.TestHTTP

  ## Usage in Tests

  The test transport exposes functions to simulate Socket Mode events:

  ### Emit events to trigger handlers

      test "handles app_mention events" do
        {:ok, _pid} = start_supervised(MyApp.SlackBot)

        # Get the transport PID
        transport = get_transport_pid(MyApp.SlackBot)

        # Simulate Slack sending an app_mention
        SlackBot.TestTransport.emit(transport, "app_mention", %{
          "type" => "app_mention",
          "channel" => "C123",
          "user" => "U456",
          "text" => "<@BOTID> help",
          "ts" => "1234567890.123456"
        })

        # Assert your handler's side effects
        assert_receive {:message_sent, "C123", _text}
      end

  ### Simulate disconnects

      test "handles disconnect gracefully" do
        transport = get_transport_pid(MyApp.SlackBot)

        SlackBot.TestTransport.disconnect(transport, %{
          "reason" => "warning",
          "debug_info" => %{"host" => "applink.example"}
        })

        # Assert reconnection behavior
        assert_receive {:connection_state, :reconnecting}
      end

  ## Getting the Transport PID

  Helper to extract transport PID in tests:

      defp get_transport_pid(bot) do
        config = SlackBot.config(bot)
        manager = Module.concat(config.instance_name, ConnectionManager)

        # Implementation depends on your test setup
        # You may need to add a helper to ConnectionManager
        :sys.get_state(manager).transport_pid
      end

  Or use the `:notify` option:

      test "emits event" do
        test_pid = self()

        config = %SlackBot.Config{
          transport: SlackBot.TestTransport,
          transport_opts: [notify: test_pid],
          # ...
        }

        start_supervised({SlackBot, config: config})

        assert_receive {:test_transport, transport_pid}

        SlackBot.TestTransport.emit(transport_pid, "message", %{...})
      end

  ## Complete Test Example

      defmodule MyApp.SlackBotTest do
        use ExUnit.Case

        setup do
          start_supervised!(MyApp.SlackBot)
          transport = get_transport_pid(MyApp.SlackBot)
          {:ok, transport: transport}
        end

        test "responds to mentions", %{transport: transport} do
          SlackBot.TestTransport.emit(transport, "app_mention", %{
            "channel" => "C123",
            "user" => "U456",
            "text" => "<@BOT> ping"
          })

          # Assert response was sent
          assert_receive {:api_call, "chat.postMessage", %{"text" => "pong"}}
        end
      end

  ## API

  - `emit/4` - Simulate Slack sending an event
  - `disconnect/2` - Simulate connection loss

  ## See Also

  - `SlackBot.TestHTTP` - Stub HTTP client for API calls
  - `BasicBot` tests for complete examples
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
