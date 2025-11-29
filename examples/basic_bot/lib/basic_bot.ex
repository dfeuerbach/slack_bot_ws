defmodule BasicBot do
  @moduledoc """
  Example SlackBot router demonstrating events, middleware, slash grammars,
  diagnostics replay, Block Kit helpers, async Web API usage, and auto-ack modes.
  """

  use SlackBot

  alias BasicBot.TelemetryProbe
  alias SlackBot.Cache
  alias SlackBot.TelemetryStats

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
    snapshot = telemetry_snapshot()
    blocks = telemetry_blocks(snapshot)

    body = %{
      channel: channel,
      text: telemetry_title(snapshot.source),
      blocks: blocks
    }

    SlackBot.push(BasicBot.SlackBot, {"chat.postMessage", body})
  end

  defp telemetry_title(:telemetry_stats), do: "Telemetry snapshot (TelemetryStats live data)"
  defp telemetry_title(:telemetry_probe), do: "Telemetry snapshot (probe fallback)"

  defp telemetry_snapshot do
    bot = BasicBot.SlackBot

    case TelemetryStats.snapshot(bot) do
      %{stats: stats} = raw when is_map(stats) and stats != %{} ->
        normalize_stats_snapshot(raw, bot)

      _ ->
        normalize_probe_snapshot(TelemetryProbe.snapshot(bot))
    end
  end

  defp normalize_stats_snapshot(%{stats: stats, generated_at_ms: ms}, bot) do
    counts = cache_counts(bot)
    cache_sync = Map.get(stats, :cache_sync, %{})

    %{
      source: :telemetry_stats,
      generated_at: DateTime.from_unix!(ms, :millisecond),
      cache:
        Map.merge(counts, %{
          last_sync_kind: cache_sync[:last_kind],
          last_sync_status: cache_sync[:last_status],
          last_sync_count: cache_sync[:last_count],
          last_sync_duration_ms: cache_sync[:last_duration_ms]
        }),
      api: %{
        total: stats.api.total,
        ok: stats.api.ok,
        error: stats.api.error,
        exception: stats.api.exception,
        unknown: stats.api.unknown,
        avg_duration_ms: average(stats.api.duration_ms, stats.api.total),
        rate_limited: stats.api.rate_limited,
        last_method: stats.api.last_method,
        last_rate_limited: stats.api.last_rate_limited
      },
      handler: Map.put(stats.handler, :available?, true),
      rate_limiter: %{
        allow: stats.rate_limiter.allow,
        queue: stats.rate_limiter.queue,
        drains: stats.rate_limiter.drains,
        last_queue: stats.rate_limiter.last_queue,
        last_block_delay_ms:
          stats.rate_limiter.last_block_delay_ms || stats.rate_limiter.last_delay_ms
      },
      tier: %{
        allow: stats.tier.allow,
        queue: stats.tier.queue,
        last_tokens: stats.tier.last_tokens,
        suspensions: stats.tier.suspensions,
        resumes: stats.tier.resumes,
        last_suspend: stats.tier.last_suspend,
        last_resume: stats.tier.last_resume
      },
      connection: %{
        states: stats.connection.states,
        last_state: stats.connection.last_state,
        rate_limited: stats.connection.rate_limited,
        last_rate_delay_ms: stats.connection.last_rate_delay_ms
      },
      health: %{
        statuses: stats.health.statuses,
        last_status: stats.health.last_status,
        disabled?: false,
        failures:
          Map.get(stats.health.statuses, :error, 0) + Map.get(stats.health.statuses, :fatal, 0)
      },
      ack: stats.ack
    }
  end

  defp normalize_probe_snapshot(%{
         generated_at: generated_at,
         cache: cache,
         api: api,
         tier: tier,
         rate_limiter: rate_limiter,
         connection: connection,
         health: health,
         ack: ack
       }) do
    %{
      source: :telemetry_probe,
      generated_at: generated_at,
      cache: %{
        users: cache.users,
        channels: cache.channels,
        last_sync_kind: cache.last_sync_kind,
        last_sync_status: cache.last_sync_status,
        last_sync_count: cache.last_sync_count,
        last_sync_duration_ms: cache.last_sync_duration_ms
      },
      api: %{
        total: api.total,
        ok: api.ok,
        error: api.error,
        exception: 0,
        unknown: api.unknown,
        avg_duration_ms: api.avg_duration_ms,
        rate_limited: api.rate_limited,
        last_method: nil,
        last_rate_limited: nil
      },
      handler: %{available?: false},
      rate_limiter: %{
        allow: rate_limiter.allow,
        queue: rate_limiter.queue,
        drains: rate_limiter.drains,
        last_queue: rate_limiter.last_queue,
        last_block_delay_ms: nil
      },
      tier: %{
        allow: tier.allow,
        queue: tier.queue,
        last_tokens: tier.last_queue,
        suspensions: 0,
        resumes: 0,
        last_suspend: nil,
        last_resume: nil
      },
      connection: %{
        states: connection.states,
        last_state: connection.last_state,
        rate_limited: connection.rate_limited,
        last_rate_delay_ms: nil
      },
      health: %{
        statuses: %{},
        last_status:
          case health.last_status do
            nil -> nil
            status -> %{status: status, duration_ms: nil, reason: nil}
          end,
        disabled?: health.disabled,
        failures: health.failures
      },
      ack: Map.put_new(ack, :exception, 0)
    }
  end

  defp cache_counts(bot) do
    %{
      users: bot |> Cache.users() |> map_size(),
      channels: bot |> Cache.channels() |> length()
    }
  rescue
    _ -> %{users: 0, channels: 0}
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
  def telemetry_blocks(%{source: source} = snapshot) do
    [
      SlackBot.Blocks.section("*Runtime telemetry snapshot*"),
      SlackBot.Blocks.context([
        "Generated #{format_ts(snapshot.generated_at)} • Source: #{format_source(source)}"
      ]),
      SlackBot.Blocks.divider(),
      section_with_fields("*Cache & Sync*", cache_fields(snapshot)),
      section_with_fields("*Handlers & API*", handler_api_fields(snapshot)),
      section_with_fields("*Rate & Tier Limiters*", limiter_fields(snapshot)),
      section_with_fields("*Connection & Health*", connection_fields(snapshot))
    ]
  end

  def telemetry_blocks(snapshot) when is_map(snapshot) do
    snapshot
    |> upgrade_legacy_snapshot()
    |> telemetry_blocks()
  end

  defp upgrade_legacy_snapshot(snapshot) do
    snapshot
    |> Map.put_new(:source, :legacy)
    |> Map.put_new(:handler, %{available?: false})
    |> Map.update(:ack, %{}, fn ack -> Map.put_new(ack, :exception, 0) end)
    |> Map.update(:tier, %{}, fn tier ->
      Map.merge(
        %{
          last_tokens: 0.0,
          suspensions: 0,
          resumes: 0,
          last_suspend: nil,
          last_resume: nil
        },
        tier
      )
    end)
    |> Map.update(:rate_limiter, %{}, fn rl ->
      Map.put_new(rl, :last_block_delay_ms, nil)
    end)
    |> Map.update(:connection, %{}, fn conn ->
      Map.put_new(conn, :last_rate_delay_ms, nil)
    end)
  end

  defp cache_fields(%{cache: cache, source: source}) do
    [
      field("*Cache coverage*\nUsers #{cache.users} • Channels #{cache.channels}"),
      field("*Last sync*\n#{format_sync_line(cache)}"),
      field("*Records processed*\n#{format_sync_volume(cache)}"),
      field("*Data source*\n#{format_source(source)}")
    ]
  end

  defp handler_api_fields(%{api: api, handler: handler, ack: ack}) do
    [
      field("*API requests*\n#{format_request_counts(api)}"),
      field("*Latency & rate limits*\n#{format_latency(api)}"),
      field("*Handler outcomes*\n#{format_handler_status(handler)}"),
      field("*Ingress & acks*\n#{format_ingress(handler)}\nAck: #{format_ack(ack)}")
    ]
  end

  defp limiter_fields(%{rate_limiter: rate_limiter, tier: tier}) do
    [
      field("*Runtime limiter*\n#{format_runtime_limiter(rate_limiter)}"),
      field("*Backpressure*\n#{format_block_delay(rate_limiter)}"),
      field("*Tier quotas*\n#{format_tier_line(tier)}"),
      field("*Tier activity*\n#{format_tier_activity(tier)}")
    ]
  end

  defp connection_fields(%{connection: connection, health: health}) do
    [
      field("*States observed*\n#{format_states(connection.states)}"),
      field("*Last state*\n#{format_last_state(connection.last_state)}"),
      field("*Rate-limited reconnects*\n#{format_rate_limited(connection)}"),
      field("*Health checks*\n#{format_health(health)}")
    ]
  end

  defp format_source(:telemetry_stats), do: "TelemetryStats (cache-backed)"
  defp format_source(:telemetry_probe), do: "TelemetryProbe (legacy sample)"
  defp format_source(:legacy), do: "Legacy snapshot"
  defp format_source(other), do: inspect(other)

  defp format_sync_line(%{last_sync_kind: nil}),
    do: "Sync pending (first run kicks off automatically)"

  defp format_sync_line(%{last_sync_kind: kind, last_sync_status: status}),
    do: "#{kind} • #{status}"

  defp format_sync_volume(%{last_sync_count: count, last_sync_duration_ms: duration})
       when is_integer(count) and count > 0 do
    "#{count} records in #{format_ms(duration)}"
  end

  defp format_sync_volume(_), do: "No cache syncs have completed yet"

  defp format_request_counts(api) do
    failures = Map.get(api, :error, 0) + Map.get(api, :exception, 0)

    "*Total* #{api.total}\n*OK* #{api.ok} • *Failures* #{failures} • *Other* #{api.unknown}"
  end

  defp format_latency(api) do
    avg = format_ms(api.avg_duration_ms)

    rate_hits = Map.get(api, :rate_limited, 0)
    last_method = Map.get(api, :last_method)

    [
      avg && "Avg #{avg}",
      rate_hits > 0 && "#{rate_hits} rate-limit hits",
      last_method && "Last method #{last_method}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" • ")
  end

  defp format_handler_status(%{available?: false}),
    do: "Enable `telemetry_stats` to see handler outcomes"

  defp format_handler_status(%{status: status, duration_ms: duration}) do
    total = Enum.reduce(status, 0, fn {_k, v}, acc -> acc + v end)
    avg = average(duration, total)

    [
      "ok #{Map.get(status, :ok, 0)}",
      "error #{Map.get(status, :error, 0)}",
      "exception #{Map.get(status, :exception, 0)}",
      "halted #{Map.get(status, :halted, 0)}",
      "other #{Map.get(status, :unknown, 0)}",
      "avg #{format_ms(avg)}"
    ]
    |> Enum.join(" • ")
  end

  defp format_ingress(%{available?: false}), do: "No ingress metrics (enable telemetry_stats)"

  defp format_ingress(%{ingress: ingress, middleware_halts: halts}) do
    queue = Map.get(ingress, :queue, 0)
    duplicates = Map.get(ingress, :duplicate, 0)
    "queued #{queue} • duplicates #{duplicates} • halts #{halts}"
  end

  defp format_ack(ack) do
    [
      "ok #{Map.get(ack, :ok, 0)}",
      "error #{Map.get(ack, :error, 0)}",
      "exception #{Map.get(ack, :exception, 0)}",
      "other #{Map.get(ack, :unknown, 0)}"
    ]
    |> Enum.join(" • ")
  end

  defp format_runtime_limiter(rate_limiter) do
    "allow #{rate_limiter.allow} • queue #{rate_limiter.queue} • drains #{rate_limiter.drains}"
  end

  defp format_block_delay(%{last_block_delay_ms: nil}),
    do: "No recent runtime blocks"

  defp format_block_delay(%{last_block_delay_ms: delay}),
    do: "Last block delay #{format_ms(delay)}"

  defp format_tier_line(tier) do
    tokens = Float.round(tier.last_tokens || 0.0, 2)
    "allow #{tier.allow} • queue #{tier.queue} • tokens #{tokens}"
  end

  defp format_tier_activity(tier) do
    parts = [
      "susp #{tier.suspensions}",
      "resume #{tier.resumes}",
      tier.last_suspend && "last suspend #{format_scope(tier.last_suspend)}",
      tier.last_resume && "last resume #{format_scope(tier.last_resume)}"
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" • ")
    |> case do
      "" -> "No tier suspensions observed"
      text -> text
    end
  end

  defp format_scope(%{method: method, scope_key: scope, delay_ms: delay}) do
    base = "#{method} (#{scope})"
    if delay, do: "#{base} • #{format_ms(delay)}", else: base
  end

  defp format_scope(%{method: method, scope_key: scope}), do: "#{method} (#{scope})"
  defp format_scope(_), do: nil

  defp format_states(states) when states == %{}, do: "No transitions yet"

  defp format_states(states) do
    states
    |> Enum.sort_by(fn {_state, count} -> -count end)
    |> Enum.map_join(" • ", fn {state, count} -> "#{state}: #{count}" end)
  end

  defp format_last_state(nil), do: "No state reported"
  defp format_last_state(state), do: to_string(state)

  defp format_rate_limited(%{rate_limited: 0}), do: "No rate-limited reconnects"

  defp format_rate_limited(%{rate_limited: count, last_rate_delay_ms: delay}) do
    delay_text =
      case delay do
        nil -> nil
        value -> "last delay #{format_ms(value)}"
      end

    ["#{count} events", delay_text]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" • ")
  end

  defp format_health(%{disabled?: true}), do: "Disabled in config"

  defp format_health(%{last_status: nil}), do: "No health pings yet"

  defp format_health(
         %{last_status: %{status: status, duration_ms: duration, reason: reason}} = health
       ) do
    base = "#{status} in #{format_ms(duration)}"
    reason_text = reason && "reason #{inspect(reason)}"

    [base, reason_text, format_health_failures(health)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" • ")
  end

  defp format_health(%{last_status: status} = health) when is_atom(status) do
    "#{status} • #{format_health_failures(health)}"
  end

  defp format_health_failures(%{failures: failures}) when failures > 0,
    do: "#{failures} failures"

  defp format_health_failures(_), do: nil

  defp format_ms(nil), do: "n/a"

  defp format_ms(value) when is_number(value) do
    cond do
      value >= 1_000 ->
        "#{Float.round(value / 1_000, 2)} s"

      true ->
        "#{Float.round(value, 2)} ms"
    end
  end

  defp format_ms(_), do: "n/a"

  defp format_ts(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_ts(_), do: "unknown"

  defp average(_total_ms, 0), do: 0.0
  defp average(total_ms, count), do: total_ms / count

  defp section_with_fields(title, fields) do
    %{
      "type" => "section",
      "text" => SlackBot.Blocks.markdown(title),
      "fields" => fields
    }
  end

  defp field(text), do: %{type: "mrkdwn", text: text}

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
