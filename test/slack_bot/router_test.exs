defmodule SlackBot.RouterTest do
  use ExUnit.Case, async: true

  defmodule TestMiddleware do
    def call("message", payload, ctx), do: {:cont, Map.put(payload, "tag", :processed), ctx}
    def call(_type, payload, ctx), do: {:cont, payload, ctx}
  end

  defmodule DemoRouter do
    use SlackBot

    middleware(TestMiddleware)

    handle_event "message", event, ctx do
      send(ctx.assigns.test_pid, {:message, event})
    end

    handle_slash "/deploy", cmd, ctx do
      send(ctx.assigns.test_pid, {:slash, cmd["parsed"]})
    end
  end

  test "dispatches message events" do
    ctx = %{assigns: %{test_pid: self()}}
    DemoRouter.handle_event("message", %{"text" => "hi"}, ctx)

    assert_receive {:message, %{"text" => "hi", "tag" => :processed}}
  end

  test "parses slash commands" do
    ctx = %{assigns: %{test_pid: self()}}

    DemoRouter.handle_event(
      "slash_commands",
      %{"command" => "/deploy", "text" => "app --env=prod"},
      ctx
    )

    assert_receive {:slash, %{command: "deploy", flags: %{env: "prod"}}}
  end
end
