defmodule BasicBot do
  @moduledoc """
  Example SlackBot router demonstrating events, middleware, slash grammars,
  diagnostics replay, Block Kit helpers, async Web API usage, and auto-ack modes.
  """

  use SlackBot

  middleware SlackBot.Middleware.Logger

  handle_event "app_mention", event, ctx do
    respond(event["channel"], "Hi <@#{event["user"]}>! Try `/demo list short fleet` or `/demo help`.", ctx)
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
        sequence do
          literal "blocks", as: :mode, value: :blocks
        end
        sequence do
          literal "ping-ephemeral", as: :mode, value: :ping_ephemeral
        end
        sequence do
          literal "async-demo", as: :mode, value: :async_demo
        end
        sequence do
          literal "help", as: :mode, value: :help
        end
      end
    end

    handle payload, ctx do
      parsed = payload["parsed"]
      channel = payload["channel_id"]

      case parsed.mode do
        :list ->
          respond(channel, format_response(parsed), ctx)

        :report ->
          respond(channel, format_response(parsed), ctx)

        :blocks ->
          send_blocks_demo(channel, ctx)

        :ping_ephemeral ->
          send_ephemeral_ping(payload, ctx)

        :async_demo ->
          run_async_demo(channel, ctx)

        :help ->
          respond(channel, help_text(), ctx)
      end
    end
  end

  defp respond(channel, text, _ctx) do
    body = %{channel: channel, text: text}
    SlackBot.push(BasicBot.SlackBot, {"chat.postMessage", body})
  end

  defp send_blocks_demo(channel, _ctx) do
    blocks =
      SlackBot.Blocks.build(BasicBot.SlackBot, fn ->
        [
          SlackBot.Blocks.section("*BasicBot* Block Kit demo"),
          SlackBot.Blocks.divider(),
          SlackBot.Blocks.section("Here is a primary button:",
            accessory: SlackBot.Blocks.button("Click me", style: :primary, value: "demo-1")
          ),
          SlackBot.Blocks.context([
            "Built via SlackBot.Blocks helpers.",
            "BlockBox enabled?: #{SlackBot.Blocks.blockbox?(BasicBot.SlackBot)}"
          ])
        ]
      end)

    body = %{
      channel: channel,
      text: "BasicBot Block Kit demo",
      blocks: blocks
    }

    SlackBot.push(BasicBot.SlackBot, {"chat.postMessage", body})
  end

  defp send_ephemeral_ping(payload, _ctx) do
    body = %{
      channel: payload["channel_id"],
      user: payload["user_id"],
      text: "This is an ephemeral response only you can see."
    }

    SlackBot.push(BasicBot.SlackBot, {"chat.postEphemeral", body})
  end

  defp run_async_demo(channel, _ctx) do
    Enum.each(1..3, fn i ->
      body = %{channel: channel, text: "Async message #{i} of 3 from BasicBot."}
      SlackBot.push_async(BasicBot.SlackBot, {"chat.postMessage", body})
    end)

    final = %{channel: channel, text: "Async demo complete."}
    SlackBot.push_async(BasicBot.SlackBot, {"chat.postMessage", final})
  end

  defp help_text do
    """
    `/demo list [short] SUBJECT [tag TAG ...]` - list details for a subject with optional tags.
    `/demo report TEAM` - queue a diagnostics report for a team.
    `/demo blocks` - send a Block Kit message (uses BlockBox when configured).
    `/demo ping-ephemeral` - send an ephemeral message visible only to you.
    `/demo async-demo` - send a series of async messages followed by a final one.
    """
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
