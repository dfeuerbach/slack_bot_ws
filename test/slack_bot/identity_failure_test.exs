defmodule SlackBot.IdentityFailureTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SlackBot.Cache
  alias SlackBot.EventBuffer

  defmodule IdentityErrorHTTP do
    def apps_connections_open(_config), do: {:ok, "wss://test.example/socket"}
    def post(_config, "auth.test", _body), do: {:error, {:slack_error, "invalid_auth"}}
    def post(_config, _method, body), do: {:ok, body}
  end

  setup do
    Application.delete_env(:slack_bot_ws, SlackBot)

    instance = __MODULE__.Instance

    config_opts = [
      app_token: "xapp-conn",
      bot_token: "xoxb-conn",
      module: SlackBot.TestHandler,
      transport: SlackBot.TestTransport,
      transport_opts: [notify: self()],
      http_client: IdentityErrorHTTP,
      assigns: %{test_pid: self()},
      instance_name: instance
    ]

    {:ok, _} = start_supervised({SlackBot.ConfigServer, name: :id_config, config: config_opts})
    config = SlackBot.ConfigServer.config(:id_config)

    Cache.child_specs(config)
    |> Enum.each(&start_supervised!(&1))

    start_supervised!(EventBuffer.child_spec(config))
    {:ok, _} = start_supervised({Task.Supervisor, name: :id_tasks})

    {:ok, %{}}
  end

  test "logs and does not connect when identity discovery fails" do
    log =
      capture_log(fn ->
        {:ok, _pid} =
          start_supervised(
            {SlackBot.ConnectionManager,
             name: :id_manager, config_server: :id_config, task_supervisor: :id_tasks}
          )

        refute_receive {:test_transport, _pid}, 50
      end)

    assert log =~ "failed to discover bot user id"
  end
end
