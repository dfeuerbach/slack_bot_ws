defmodule SlackBot.APITest do
  use ExUnit.Case, async: false

  alias SlackBot.API
  alias SlackBot.Config

  defmodule MockReq do
    def post(opts) do
      handler = Process.get(:req_test_handler) || raise "no req handler configured"
      handler.(opts)
    end
  end

  setup do
    original = Application.get_env(:slack_bot_ws, SlackBot.API)
    Application.put_env(:slack_bot_ws, SlackBot.API, req_impl: MockReq)

    on_exit(fn ->
      if original do
        Application.put_env(:slack_bot_ws, SlackBot.API, original)
      else
        Application.delete_env(:slack_bot_ws, SlackBot.API)
      end

      Process.delete(:req_test_handler)
    end)

    :ok
  end

  defp config do
    %Config{
      app_token: "xapp-test",
      bot_token: "xoxb-test",
      module: SlackBot.TestHandler,
      instance_name: APITest.Instance
    }
  end

  test "apps_connections_open returns URL on success" do
    Process.put(:req_test_handler, fn opts ->
      assert opts[:url] == "https://slack.com/api/apps.connections.open"
      assert {"authorization", "Bearer xapp-test"} in opts[:headers]
      {:ok, %{body: %{"ok" => true, "url" => "wss://socket"}}}
    end)

    assert {:ok, "wss://socket"} = API.apps_connections_open(config())
  end

  test "apps_connections_open surfaces rate limit from body" do
    Process.put(:req_test_handler, fn _opts ->
      {:ok, %{body: %{"ok" => false, "error" => "ratelimited", "retry_after" => 12}}}
    end)

    assert {:rate_limited, 12} = API.apps_connections_open(config())
  end

  test "apps_connections_open falls back to Retry-After header" do
    Process.put(:req_test_handler, fn _opts ->
      {:ok,
       %{
         body: %{"ok" => false, "error" => "ratelimited"},
         headers: [{"Retry-After", "3"}]
       }}
    end)

    assert {:rate_limited, 3} = API.apps_connections_open(config())
  end

  test "post/2 sends bot token and body" do
    Process.put(:req_test_handler, fn opts ->
      assert {"authorization", "Bearer xoxb-test"} in opts[:headers]
      assert opts[:json] == %{"text" => "hi"}
      {:ok, %{body: %{"ok" => true, "result" => "sent"}}}
    end)

    assert {:ok, %{"ok" => true, "result" => "sent"}} =
             API.post(config(), "chat.postMessage", %{"text" => "hi"})
  end

  test "post/2 returns slack error tuple" do
    Process.put(:req_test_handler, fn _opts ->
      {:ok, %{body: %{"ok" => false, "error" => "invalid_auth"}}}
    end)

    assert {:error, {:slack_error, "invalid_auth"}} =
             API.post(config(), "chat.postMessage", %{"text" => "hi"})
  end

  test "post/2 respects configured tier limits" do
    Application.put_env(:slack_bot_ws, SlackBot.TierRegistry,
      tiers: %{"chat.postMessage" => %{max_calls: 1, window_ms: 80, scope: :workspace}}
    )

    on_exit(fn -> Application.delete_env(:slack_bot_ws, SlackBot.TierRegistry) end)

    config = config()

    start_supervised!(SlackBot.TierLimiter.child_spec(config))

    parent = self()

    handler = fn _opts ->
      send(parent, {:http_call, System.monotonic_time(:millisecond)})
      {:ok, %{body: %{"ok" => true, "result" => "ok"}}}
    end

    Process.put(:req_test_handler, handler)

    assert {:ok, %{"result" => "ok"}} =
             API.post(config, "chat.postMessage", %{"channel" => "C", "text" => "one"})

    t1 =
      receive do
        {:http_call, ts} -> ts
      end

    task =
      Task.async(fn ->
        Process.put(:req_test_handler, handler)
        API.post(config, "chat.postMessage", %{"channel" => "C", "text" => "two"})
      end)

    refute Task.yield(task, 10)

    assert {:ok, %{"result" => "ok"}} = Task.await(task, 200)

    t2 =
      receive do
        {:http_call, ts} -> ts
      end

    assert t2 - t1 >= 40
  end
end
