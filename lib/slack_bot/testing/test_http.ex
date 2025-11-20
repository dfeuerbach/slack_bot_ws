defmodule SlackBot.TestHTTP do
  @moduledoc """
  Minimal HTTP client for tests.

  Provides deterministic responses for Slack Web API calls invoked via `SlackBot.push/2`.
  """

  def apps_connections_open(_config), do: {:ok, "wss://test.example/socket"}

  def post(_config, _method, body), do: {:ok, body}
end
