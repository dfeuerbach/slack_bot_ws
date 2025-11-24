defmodule BasicBot do
  @moduledoc """
  Example SlackBot router demonstrating events, middleware, slash grammars,
  diagnostics replay, and auto-ack modes.
  """

  use SlackBot

  middleware SlackBot.Middleware.Logger

  handle_event "app_mention", event, ctx do
    respond(event["channel"], "Hi <@#{event["user"]}>! Try `/demo list short fleet`.", ctx)
  end

  slash "/demo", ack: :ephemeral do
    grammar do
      choice do
        sequence do
          literal "list", as: :mode, value: :list
          optional literal("short", as: :short?)
          value :subject

          repeat do
            literal "tag"
            value :tags
          end
        end

        sequence do
          literal "report", as: :mode, value: :report
          value :team
        end
      end
    end

    handle payload, ctx do
      parsed = payload["parsed"]
      respond(payload["channel_id"], format_response(parsed), ctx)
    end
  end

  defp respond(channel, text, _ctx) do
    body = %{channel: channel, text: text}
    SlackBot.push(BasicBot.SlackBot, {"chat.postMessage", body})
  end

  defp format_response(%{mode: :list} = parsed) do
    tags = parsed |> Map.get(:tags, []) |> Enum.join(", ")
    short? = if Map.get(parsed, :short?), do: "short ", else: ""
    "Listing #{short?}details for #{parsed.subject}. Tags: #{tags |> empty_dash()}"
  end

  defp format_response(%{mode: :report, team: team}) do
    "Queued a diagnostics report for team #{team}."
  end

  defp empty_dash(""), do: "—"
  defp empty_dash(text), do: text
end
