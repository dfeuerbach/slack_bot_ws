defmodule SlackBot.HealthMonitorTest do
  use ExUnit.Case, async: true

  alias SlackBot.HealthMonitor
  alias SlackBot.ConfigServer

  defmodule OkHTTP do
    def apps_connections_open(_config), do: {:ok, "wss://test.example/socket"}
    def post(_config, "auth.test", _body), do: {:ok, %{"ok" => true}}
    def post(_config, _method, body), do: {:ok, body}
  end

  defmodule ErrorHTTP do
    def apps_connections_open(_config), do: {:ok, "wss://test.example/socket"}
    def post(_config, "auth.test", _body), do: {:error, :econnrefused}
    def post(_config, _method, body), do: {:ok, body}
  end

  defmodule RateLimitedHTTP do
    def apps_connections_open(_config), do: {:ok, "wss://test.example/socket"}
    def post(_config, "auth.test", _body), do: {:error, {:rate_limited, 1}}
    def post(_config, _method, body), do: {:ok, body}
  end

  defmodule FatalHTTP do
    def apps_connections_open(_config), do: {:ok, "wss://test.example/socket"}
    def post(_config, "auth.test", _body), do: {:error, {:slack_error, "invalid_auth"}}
    def post(_config, _method, body), do: {:ok, body}
  end

  defmodule DummyConnMgr do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    def last_healthcheck(name) do
      GenServer.call(name, :last)
    end

    @impl true
    def init(_opts), do: {:ok, nil}

    @impl true
    def handle_info(msg, _state), do: {:noreply, msg}

    @impl true
    def handle_call(:last, _from, state), do: {:reply, state, state}
  end

  setup do
    Application.delete_env(:slack_bot_ws, SlackBot)
    :ok
  end

  defp base_opts(http_client) do
    instance = __MODULE__.Instance

    config_opts = [
      app_token: "xapp-health",
      bot_token: "xoxb-health",
      module: SlackBot.TestHandler,
      http_client: http_client,
      instance_name: instance,
      health_check: [enabled: true, interval_ms: 10]
    ]

    {:ok, _} = start_supervised({ConfigServer, name: :hm_config, config: config_opts})
    {:ok, _} = start_supervised({DummyConnMgr, name: :hm_conn})

    %{config_server: :hm_config, connection_manager: :hm_conn}
  end

  test "emits ok telemetry on successful ping" do
    %{config_server: config_server, connection_manager: conn_mgr} = base_opts(OkHTTP)

    handler_id = {:health_ok, make_ref()}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:slackbot, :healthcheck, :ping],
      fn _event, _meas, meta, _ ->
        send(parent, {:health_ping, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _pid} =
      start_supervised(
        {HealthMonitor,
         name: :hm_monitor, config_server: config_server, connection_manager: conn_mgr}
      )

    assert_receive {:health_ping, %{status: :ok}}, 200
  end

  test "sends healthcheck_failed to connection manager on generic error" do
    %{config_server: config_server, connection_manager: conn_mgr} = base_opts(ErrorHTTP)

    {:ok, _pid} =
      start_supervised(
        {HealthMonitor,
         name: :hm_monitor, config_server: config_server, connection_manager: conn_mgr}
      )

    assert eventually(fn ->
             DummyConnMgr.last_healthcheck(conn_mgr) ==
               {:slackbot, :healthcheck_failed, :econnrefused}
           end)
  end

  test "respects rate limiting without forcing reconnect" do
    %{config_server: config_server, connection_manager: conn_mgr} = base_opts(RateLimitedHTTP)

    {:ok, _pid} =
      start_supervised(
        {HealthMonitor,
         name: :hm_monitor, config_server: config_server, connection_manager: conn_mgr}
      )

    :timer.sleep(50)
    refute DummyConnMgr.last_healthcheck(conn_mgr)
  end

  test "emits fatal telemetry on invalid_auth" do
    %{config_server: config_server, connection_manager: conn_mgr} = base_opts(FatalHTTP)

    handler_id = {:health_fatal, make_ref()}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:slackbot, :healthcheck, :ping],
      fn _event, _meas, meta, _ ->
        send(parent, {:health_ping, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _pid} =
      start_supervised(
        {HealthMonitor,
         name: :hm_monitor, config_server: config_server, connection_manager: conn_mgr}
      )

    assert_receive {:health_ping, %{status: :fatal, reason: "invalid_auth"}}, 200
    refute DummyConnMgr.last_healthcheck(conn_mgr)
  end

  test "does not schedule pings when health_check is disabled" do
    instance = __MODULE__.DisabledInstance

    config_opts = [
      app_token: "xapp-health",
      bot_token: "xoxb-health",
      module: SlackBot.TestHandler,
      http_client: OkHTTP,
      instance_name: instance,
      health_check: [enabled: false, interval_ms: 10]
    ]

    {:ok, _} = start_supervised({ConfigServer, name: :hm_disabled_config, config: config_opts})
    {:ok, _} = start_supervised({DummyConnMgr, name: :hm_disabled_conn})

    handler_id = {:health_disabled, make_ref()}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:slackbot, :healthcheck, :disabled],
      fn _event, _meas, _meta, _ ->
        send(parent, :health_disabled)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _pid} =
      start_supervised(
        {HealthMonitor,
         name: :hm_disabled_monitor,
         config_server: :hm_disabled_config,
         connection_manager: :hm_disabled_conn}
      )

    assert_receive :health_disabled, 100
    :timer.sleep(50)
    refute DummyConnMgr.last_healthcheck(:hm_disabled_conn)
  end

  defp eventually(fun, attempts \\ 10)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    case fun.() do
      true ->
        true

      false ->
        :timer.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
