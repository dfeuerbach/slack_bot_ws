defmodule BasicBot do
  @moduledoc """
  Example SlackBot router demonstrating events, middleware, slash grammars,
  diagnostics replay, Block Kit helpers, async Web API usage, and auto-ack modes.
  """

  use SlackBot

  alias BasicBot.TelemetryProbe
  alias SlackBot.Cache

  middleware(SlackBot.Middleware.Logger)

  handle_event "app_mention", event, ctx do
    respond(
      event["channel"],
      "Hi <@#{event["user"]}>! Try `/demo list short fleet` or `/demo help`.",
      ctx
    )
  end

  handle_event "block_actions", payload, _ctx do
    case payload["actions"] do
      [%{"value" => "demo-1"} | _rest] ->
        channel = channel_from_payload(payload)
        ts = message_ts_from_payload(payload)

        if channel && ts do
          blocks =
            SlackBot.Blocks.build(BasicBot.SlackBot, fn ->
              [
                SlackBot.Blocks.section("✅ Thanks for clicking, <@#{payload["user"]["id"]}>!"),
                SlackBot.Blocks.context([
                  "BasicBot updated this card in place to confirm the action.",
                  "Try running `/demo blocks` again to see the original card."
                ])
              ]
            end)

          body = %{
            channel: channel,
            ts: ts,
            text: "BasicBot Block Kit demo (clicked)",
            blocks: blocks
          }

          SlackBot.push(BasicBot.SlackBot, {"chat.update", body})
        end

      _ ->
        :ok
    end
  end

  slash "/demo" do
    grammar do
      choice do
        sequence do
          literal("list", as: :mode, value: :list)
          optional(literal("short", as: :short?))
          value(:subject)

          repeat do
            literal("tag")
            value(:tags)
          end
        end

        sequence do
          literal("report", as: :mode, value: :report)
          value(:team)
        end

        sequence do
          literal("blocks", as: :mode, value: :blocks)
        end

        sequence do
          literal("ping-ephemeral", as: :mode, value: :ping_ephemeral)
        end

        sequence do
          literal("async-demo", as: :mode, value: :async_demo)
        end

        sequence do
          literal("help", as: :mode, value: :help)
        end

        sequence do
          literal("users", as: :mode, value: :users)
        end

        sequence do
          literal("channels", as: :mode, value: :channels)
        end

        sequence do
          literal("telemetry", as: :mode, value: :telemetry)
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

        :users ->
          demo_users(channel, ctx)

        :channels ->
          demo_channels(channel, ctx)

        :telemetry ->
          demo_telemetry(channel, ctx)
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

  defp demo_users(channel, _ctx) do
    users =
      BasicBot.SlackBot
      |> Cache.users()
      |> Map.values()

    blocks =
      case users do
        [] ->
          [
            SlackBot.Blocks.section("*Cached users*"),
            SlackBot.Blocks.context([
              "No cached users yet. Try again after someone interacts with the bot so their profile can be cached."
            ])
          ]

        _ ->
          users
          |> Enum.shuffle()
          |> Enum.take(5)
          |> build_user_blocks()
      end

    body = %{
      channel: channel,
      text: "Cached users from BasicBot",
      blocks: blocks
    }

    SlackBot.push(BasicBot.SlackBot, {"chat.postMessage", body})
  end

  defp demo_channels(channel, _ctx) do
    joined_ids =
      BasicBot.SlackBot
      |> Cache.channels()
      |> Enum.sort()

    channels =
      joined_ids
      |> Enum.map(fn id -> {id, Cache.get_channel(BasicBot.SlackBot, id)} end)

    blocks =
      case channels do
        [] ->
          [
            SlackBot.Blocks.section("*Joined channels*"),
            SlackBot.Blocks.context([
              "No joined channels are currently cached."
            ])
          ]

        list ->
          list
          |> Enum.take(20)
          |> build_channel_blocks(length(list))
      end

    body = %{
      channel: channel,
      text: "Joined channels from BasicBot",
      blocks: blocks
    }

    SlackBot.push(BasicBot.SlackBot, {"chat.postMessage", body})
  end

  defp demo_telemetry(channel, _ctx) do
    stats = TelemetryProbe.snapshot(BasicBot.SlackBot)
    blocks = telemetry_blocks(stats)

    body = %{
      channel: channel,
      text: "Telemetry snapshot",
      blocks: blocks
    }

    SlackBot.push(BasicBot.SlackBot, {"chat.postMessage", body})
  end

  defp build_user_blocks(users) when is_list(users) do
    header = [
      SlackBot.Blocks.section("*Cached users*"),
      SlackBot.Blocks.context([
        "Sample of up to 5 users from the metadata cache."
      ]),
      SlackBot.Blocks.divider()
    ]

    entries =
      users
      |> Enum.flat_map(fn %{"id" => id} = user ->
        profile = Map.get(user, "profile", %{})

        handle = Map.get(user, "name")
        display = Map.get(profile, "display_name")
        email = Map.get(profile, "email")
        title = Map.get(profile, "title")
        presence = Map.get(user, "presence")

        name_part =
          cond do
            display && handle -> "#{display} (#{handle})"
            display -> display
            handle -> handle
            true -> id
          end

        primary = SlackBot.Blocks.section("*<@#{id}>*  #{name_part}")

        secondary_items =
          [
            email && "*Email* #{email}",
            title && "*Title* #{title}",
            presence && "*Presence* #{presence}"
          ]
          |> Enum.reject(&is_nil/1)

        secondary =
          case secondary_items do
            [] ->
              []

            items ->
              [
                SlackBot.Blocks.context([
                  Enum.join(items, "  •  ")
                ])
              ]
          end

        [primary | secondary]
      end)

    header ++ entries
  end

  defp build_channel_blocks(channels, total_count) when is_list(channels) do
    header = [
      SlackBot.Blocks.section("*Joined channels*"),
      SlackBot.Blocks.context([
        "Showing up to 20 channels from the cache."
      ]),
      SlackBot.Blocks.divider()
    ]

    entries =
      channels
      |> Enum.flat_map(fn
        {id, %{"name" => name} = channel} ->
          visibility =
            case {channel["is_private"], channel["is_channel"]} do
              {true, _} -> "private"
              {_, true} -> "public"
              _ -> nil
            end

          members = channel["num_members"]

          primary_label =
            case visibility do
              nil -> "*##{name}*"
              vis -> "*##{name}*  _(#{vis})_"
            end

          primary = SlackBot.Blocks.section(primary_label)

          secondary_items =
            [
              members && "*Members* #{members}",
              "*ID* #{id}"
            ]
            |> Enum.reject(&is_nil/1)

          secondary =
            [
              SlackBot.Blocks.context([
                Enum.join(secondary_items, "  •  ")
              ])
            ]

          [primary | secondary]

        {id, _} ->
          [SlackBot.Blocks.section("*Channel* #{id}")]
      end)

    extra =
      case total_count - length(channels) do
        n when n > 0 ->
          [
            SlackBot.Blocks.divider(),
            SlackBot.Blocks.context(["…and #{n} more channels in the cache."])
          ]

        _ ->
          []
      end

    header ++ entries ++ extra
  end

  defp help_text do
    """
    `/demo list short fleet tag alpha tag beta` - list details for a subject with optional tags.
    `/demo report TEAM` - queue a diagnostics report for a team.
    `/demo blocks` - send a Block Kit message (uses BlockBox when configured).
    `/demo ping-ephemeral` - send an ephemeral message visible only to you.
    `/demo async-demo` - send a series of async messages followed by a final one.
    `/demo users` - show a sample of cached users with basic metadata.
    `/demo channels` - show the channels this bot has joined from the cache.
    `/demo telemetry` - render a telemetry snapshot (API stats, cache counts, limiters).
    """
  end

  @doc false
  def telemetry_blocks(%{
        generated_at: generated_at,
        cache: cache,
        api: api,
        tier: tier,
        rate_limiter: rate_limiter,
        connection: connection,
        health: health,
        ack: ack
      }) do
    [
      SlackBot.Blocks.section("*Runtime telemetry snapshot*"),
      SlackBot.Blocks.context([
        "Generated at #{DateTime.to_iso8601(generated_at)}"
      ]),
      SlackBot.Blocks.divider(),
      section_with_fields("*Cache & Sync*", cache_fields(cache)),
      section_with_fields("*API Throughput*", api_fields(api, ack)),
      section_with_fields("*Rate Limiting*", limiter_fields(rate_limiter, tier)),
      section_with_fields("*Connection & Health*", connection_fields(connection, health))
    ]
  end

  defp cache_fields(%{
         users: users,
         channels: channels,
         last_sync_kind: kind,
         last_sync_status: status,
         last_sync_count: count,
         last_sync_duration_ms: duration_ms
       }) do
    [
      field("*Users cached*\n#{users}"),
      field("*Channels cached*\n#{channels}"),
      field("*Last sync*\n#{format_sync(kind, status)}"),
      field("*Synced records*\n#{count} in #{duration_ms} ms")
    ]
  end

  defp api_fields(api, ack) do
    [
      field("*Requests*\n#{api.total} (#{api.ok} ok / #{api.error} err)"),
      field("*Avg latency*\n#{api.avg_duration_ms} ms"),
      field("*Rate limited*\n#{api.rate_limited} hits"),
      field("*Slash ack failures*\n#{ack.error}")
    ]
  end

  defp limiter_fields(rate_limiter, tier) do
    tier_busiest =
      case tier.busiest do
        {method, queued} -> "#{method} (#{queued})"
        _ -> "—"
      end

    [
      field("*Runtime limiter*\nallow #{rate_limiter.allow} / queue #{rate_limiter.queue}"),
      field("*Limiter drains*\n#{rate_limiter.drains}"),
      field("*Tier decisions*\nallow #{tier.allow} / queue #{tier.queue}"),
      field("*Busiest method*\n#{tier_busiest}")
    ]
  end

  defp connection_fields(connection, health) do
    total_states =
      connection.states
      |> Enum.map(fn {state, count} -> "#{state}: #{count}" end)
      |> Enum.join(" • ")
      |> case do
        "" -> "—"
        text -> text
      end

    [
      field("*States observed*\n#{total_states}"),
      field("*Last state*\n#{connection.last_state || "—"}"),
      field("*Health status*\n#{(health.disabled && "disabled") || health.last_status || "—"}"),
      field("*Health failures*\n#{health.failures}")
    ]
  end

  defp format_sync(nil, _status), do: "—"

  defp format_sync(kind, status) do
    "#{kind}/#{status}"
  end

  defp field(text) do
    %{type: "mrkdwn", text: text}
  end

  defp section_with_fields(title, fields) do
    %{
      "type" => "section",
      "text" => SlackBot.Blocks.markdown(title),
      "fields" => fields
    }
  end

  defp channel_from_payload(%{"channel" => %{"id" => id}}), do: id
  defp channel_from_payload(%{"container" => %{"channel_id" => id}}), do: id
  defp channel_from_payload(_), do: nil

  defp message_ts_from_payload(%{"container" => %{"message_ts" => ts}}), do: ts
  defp message_ts_from_payload(%{"message" => %{"ts" => ts}}), do: ts
  defp message_ts_from_payload(_), do: nil

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
