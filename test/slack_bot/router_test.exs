defmodule SlackBot.RouterTest do
  use ExUnit.Case, async: true

  alias SlackBot.Config

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

    slash "/deploy" do
      grammar do
        value(:service)

        optional do
          literal("env")
          value(:env)
        end
      end

      handle payload, ctx do
        send(ctx.assigns.test_pid, {:slash, payload["parsed"]})
      end
    end
  end

  defmodule AckRouter do
    use SlackBot

    slash "/deploy", ack: :silent do
      grammar do
        value(:service)
      end

      handle payload, ctx do
        send(ctx.assigns.test_pid, {:slash_ack_override, payload["parsed"]})
      end
    end
  end

  test "dispatches message events" do
    ctx = ctx(DemoRouter)
    DemoRouter.handle_event("message", %{"text" => "hi"}, ctx)

    assert_receive {:message, %{"text" => "hi", "tag" => :processed}}
  end

  test "parses slash commands" do
    ctx = ctx(DemoRouter)

    DemoRouter.handle_event(
      "slash_commands",
      %{"command" => "/deploy", "text" => "app env prod"},
      ctx
    )

    assert_receive {:slash, %{command: "deploy", service: "app", env: "prod"}}
  end

  defmodule GrammarRouter do
    use SlackBot

    slash "/cmd" do
      grammar do
        choice do
          sequence do
            literal("list", as: :mode, value: :list)
            optional(literal("short", as: :short?))
            value(:app)

            repeat do
              literal("param")
              value(:params)
            end
          end

          sequence do
            literal("project", as: :mode, value: :project_report)
            literal("report")
          end

          sequence do
            literal("team", as: :mode, value: :team_show)
            value(:team_name)
            literal("show")
          end

          sequence do
            literal("report", as: :mode, value: :report_teams)

            repeat do
              literal("team")
              value(:teams)
            end
          end
        end
      end

      handle payload, ctx do
        send(ctx.assigns.test_pid, {:dsl, payload["parsed"]})
      end
    end
  end

  test "dsl grammar parses optional flags and values" do
    ctx = %{assigns: %{test_pid: self()}}

    GrammarRouter.handle_event(
      "slash_commands",
      %{"command" => "/cmd", "text" => "list short app param one param two"},
      ctx
    )

    assert_receive {:dsl,
                    %{
                      command: "cmd",
                      mode: :list,
                      short?: true,
                      app: "app",
                      params: ["one", "two"]
                    }}
  end

  test "dsl grammar handles literal project report" do
    ctx = ctx(GrammarRouter)

    GrammarRouter.handle_event(
      "slash_commands",
      %{"command" => "/cmd", "text" => "project report"},
      ctx
    )

    assert_receive {:dsl, %{command: "cmd", mode: :project_report}}
  end

  test "dsl grammar handles team show with value" do
    ctx = ctx(GrammarRouter)

    GrammarRouter.handle_event(
      "slash_commands",
      %{"command" => "/cmd", "text" => "team marketing show"},
      ctx
    )

    assert_receive {:dsl, %{command: "cmd", mode: :team_show, team_name: "marketing"}}
  end

  test "dsl grammar handles repeated team values" do
    ctx = ctx(GrammarRouter)

    GrammarRouter.handle_event(
      "slash_commands",
      %{"command" => "/cmd", "text" => "report team one team two team three"},
      ctx
    )

    assert_receive {:dsl, %{command: "cmd", mode: :report_teams, teams: ["one", "two", "three"]}}
  end

  test "slash command inherits config-level ack mode" do
    parent = self()

    ack_fun = fn payload, _config ->
      send(parent, {:ack_invoked, payload["text"]})
      :ok
    end

    ctx = ctx(DemoRouter, ack_mode: {:custom, ack_fun})

    DemoRouter.handle_event(
      "slash_commands",
      %{"command" => "/deploy", "text" => "app env prod"},
      ctx
    )

    assert_receive {:ack_invoked, "app env prod"}
  end

  test "slash command options override ack mode" do
    parent = self()

    ack_fun = fn payload, _config ->
      send(parent, {:ack_invoked, payload["text"]})
      :ok
    end

    ctx = ctx(AckRouter, ack_mode: {:custom, ack_fun})

    AckRouter.handle_event(
      "slash_commands",
      %{"command" => "/deploy", "text" => "svc"},
      ctx
    )

    assert_receive {:slash_ack_override, %{command: "deploy", service: "svc"}}
    refute_receive {:ack_invoked, _}
  end

  defp ctx(module, overrides \\ []) do
    assigns = %{test_pid: self()}
    config = build_config(module, Keyword.put(overrides, :assigns, assigns))
    %{assigns: assigns, config: config}
  end

  defp build_config(module, overrides) do
    base =
      Map.from_struct(%Config{
        app_token: "xapp",
        bot_token: "xoxb",
        module: module,
        assigns: overrides[:assigns],
        instance_name: RouterTest.Instance
      })

    struct!(Config, Map.merge(base, Map.new(overrides)))
  end
end
