defmodule SlackBot.TestHTTP do
  @moduledoc """
  Minimal HTTP client for tests.

  Provides deterministic responses for Slack Web API calls invoked via `SlackBot.push/2`.
  """

  def apps_connections_open(_config), do: {:ok, "wss://test.example/socket"}

  # Simulate Slack Web API responses:
  # - auth.test returns a user_id so the connection manager can discover the bot identity.
  # - other methods echo the body to keep push/push_async tests simple.
  def post(_config, "auth.test", _body), do: {:ok, %{"ok" => true, "user_id" => "B1"}}
  def post(_config, _method, body), do: {:ok, body}
end
