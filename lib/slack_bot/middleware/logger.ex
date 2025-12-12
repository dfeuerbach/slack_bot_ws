defmodule SlackBot.Middleware.Logger do
  @moduledoc """
  Simple middleware that logs incoming Slack events at the `:debug` level.

  ## What is Middleware?

  Middleware runs before your event handlers, allowing you to:

  - Log, filter, or transform events before they reach handlers
  - Short-circuit the pipeline by returning `{:halt, response}`
  - Enrich the context (`ctx`) with computed data for downstream handlers
  - Perform side effects like metrics collection or audit logging

  Middleware modules implement a `call/3` function that receives:

  - `type` - The Slack event type (e.g., `"message"`, `"app_mention"`)
  - `payload` - The raw event payload from Slack
  - `ctx` - The event context struct containing telemetry prefix, assigns, and more

  ## Usage

  Add middleware to your router:

      defmodule MyApp.SlackBot do
        use SlackBot, otp_app: :my_app

        middleware SlackBot.Middleware.Logger

        handle_event "message", event, _ctx do
          # Your handler logic
        end
      end

  Multiple middleware run in declaration order.

  ## Writing Custom Middleware

  Create your own middleware by implementing `call/3`:

      defmodule MyApp.AuthMiddleware do
        def call(type, payload, ctx) do
          case authorized?(payload["user"]) do
            true ->
              {:cont, payload, ctx}

            false ->
              # Short-circuit: no handlers will run
              {:halt, %{ok: false, error: "unauthorized"}}
          end
        end

        defp authorized?(user_id), do: # your logic
      end

  Then add it to your router:

      middleware MyApp.AuthMiddleware
      middleware SlackBot.Middleware.Logger

  ## See Also

  - The event routing DSL (`handle_event`, `slash`, `middleware` macros)
  - Example app: `examples/basic_bot/`
  """

  require Logger

  @doc """
  Logs the event type and payload at `:debug` level, then continues the pipeline.
  """
  def call(type, payload, ctx) do
    Logger.debug("[SlackBot] event=#{type} payload=#{inspect(payload)}")
    {:cont, payload, ctx}
  end
end
