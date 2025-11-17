defmodule SlackBot.ConfigServerTest do
  use ExUnit.Case, async: true

  alias SlackBot.ConfigServer

  @opts [app_token: "xapp-789", bot_token: "xoxb-789", module: SlackBot.TestHandler]

  setup do
    original = Application.get_env(:slack_bot_ws, SlackBot)
    Application.delete_env(:slack_bot_ws, SlackBot)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:slack_bot_ws, SlackBot),
        else: Application.put_env(:slack_bot_ws, SlackBot, original)
    end)

    {:ok, pid} = start_supervised({ConfigServer, name: :config_server_test, config: @opts})
    %{server: :config_server_test, pid: pid}
  end

  test "returns config via call", %{server: server} do
    assert %SlackBot.Config{app_token: "xapp-789"} = ConfigServer.config(server)
  end

  test "reload/2 swaps configuration when valid", %{server: server} do
    assert :ok =
             ConfigServer.reload(
               [app_token: "new-app", bot_token: "xoxb-789", module: SlackBot.TestHandler],
               server
             )

    assert %SlackBot.Config{app_token: "new-app"} = ConfigServer.config(server)
  end

  test "reload/2 rejects invalid overrides", %{server: server} do
    assert {:error, {:missing_option, :bot_token}} =
             ConfigServer.reload([app_token: "missing"], server)

    assert %SlackBot.Config{app_token: "xapp-789"} = ConfigServer.config(server)
  end
end
