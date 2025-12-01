defmodule SlackBot.TestHTTP do
  @moduledoc """
  Stub HTTP client for testing without hitting Slack's API.

  Swap this in during tests to avoid real API calls while still exercising your
  handler logic. Returns deterministic responses that let you focus on testing
  your bot's behavior, not Slack's API.

  ## Usage in Tests

  Configure your test bot to use this client:

      # config/test.exs
      config :my_app, MyApp.SlackBot,
        http_client: SlackBot.TestHTTP

  Or override per-test:

      test "posts welcome message" do
        config = %SlackBot.Config{
          http_client: SlackBot.TestHTTP,
          # ... other test config
        }

        # Your SlackBot.push calls use TestHTTP automatically
        assert {:ok, response} = SlackBot.push(config, {"chat.postMessage", body})
      end

  ## Default Behavior

  - `auth.test` - Returns bot user ID so connection manager boots properly
  - All other methods - Echo back the request body

  This echo behavior is perfect for testing that your handlers construct the
  right API payloads without caring about Slack's actual response.

  ## Customizing Responses

  For tests that need specific Slack responses, wrap or extend this module:

      defmodule MyApp.TestHTTP do
        def post(config, "chat.postMessage", body) do
          {:ok, %{
            "ok" => true,
            "channel" => body["channel"],
            "ts" => "1234567890.123456",
            "message" => %{"text" => body["text"]}
          }}
        end

        def post(config, "users.info", %{"user" => "U123"}) do
          {:ok, %{
            "ok" => true,
            "user" => %{
              "id" => "U123",
              "name" => "testuser",
              "profile" => %{"email" => "test@example.com"}
            }
          }}
        end

        # Delegate everything else to the default
        def post(config, method, body) do
          SlackBot.TestHTTP.post(config, method, body)
        end
      end

  ## Example Test

      test "notifies channel on error" do
        # TestHTTP is configured in test.exs
        MyBot.handle_error(%{channel: "C123", error: "oops"})

        # Assert the API call was made
        # (implementation depends on your test strategy)
      end

  ## See Also

  - `SlackBot.TestTransport` - Simulates Socket Mode events
  - Your test suite setup in `test/test_helper.exs`
  """

  def apps_connections_open(_config), do: {:ok, "wss://test.example/socket"}

  # Simulate Slack Web API responses:
  # - auth.test returns a user_id so the connection manager can discover the bot identity.
  # - other methods echo the body to keep push/push_async tests simple.
  def post(_config, "auth.test", _body), do: {:ok, %{"ok" => true, "user_id" => "B1"}}
  def post(_config, _method, body), do: {:ok, body}
end
