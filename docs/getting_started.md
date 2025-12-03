# Getting Started

This guide walks you through creating a Slack bot from scratch—configuring a Slack App, obtaining tokens, and running your first handler.

## Prerequisites

- Elixir 1.14 or later
- A Slack workspace where you have permission to install apps
- Access to [api.slack.com](https://api.slack.com/apps)

## 1. Create a Slack App

1. Go to [api.slack.com/apps](https://api.slack.com/apps) and click **Create New App**.
2. Choose **From scratch**, give it a name (e.g., "MyBot"), and select your workspace.
3. You'll land on the app's **Basic Information** page.

## 2. Enable Socket Mode

Socket Mode lets your bot receive events over a WebSocket instead of exposing a public HTTP endpoint.

1. In the left sidebar, click **Socket Mode**.
2. Toggle **Enable Socket Mode** on.
3. You'll be prompted to generate an **App-Level Token**. Give it a name like `socket-token` and add the `connections:write` scope.
4. Copy the token (it starts with `xapp-`). This is your `SLACK_APP_TOKEN`.

## 3. Add Bot Scopes

1. In the sidebar, go to **OAuth & Permissions**.
2. Scroll to **Scopes** → **Bot Token Scopes** and add the scopes your bot needs. At minimum:
   - `chat:write` — send messages
   - `commands` — receive slash commands (if you plan to use them)
   - `channels:read` — read channel metadata (for the cache sync)
3. If you want your bot to respond to messages or mentions, add `app_mentions:read` and/or `channels:history`.

## 4. Install the App

1. Still on **OAuth & Permissions**, scroll up and click **Install to Workspace**.
2. Authorize the app.
3. Copy the **Bot User OAuth Token** (starts with `xoxb-`). This is your `SLACK_BOT_TOKEN`.

## 5. Subscribe to Events

If your bot needs to react to messages, mentions, or other events:

1. Go to **Event Subscriptions** in the sidebar.
2. Toggle **Enable Events** on. (Socket Mode handles delivery, so you won't need a Request URL.)
3. Under **Subscribe to bot events**, add events like:
   - `message.channels` — messages in public channels the bot is in
   - `app_mention` — when someone @mentions your bot
4. Save changes.

## 6. Create a Slash Command (optional)

1. Go to **Slash Commands** in the sidebar.
2. Click **Create New Command**.
3. Fill in the command (e.g., `/demo`), a short description, and usage hint.
4. Save. Slack will deliver slash-command payloads over the Socket Mode connection.

## 7. Add SlackBot to Your Project

In your `mix.exs`:

```elixir
def deps do
  [
    {:slack_bot_ws, "~> 0.1.0"}
  ]
end
```

Run:

```bash
mix deps.get
```

## 8. Scaffold with Igniter (optional)

If you have [Igniter](https://hexdocs.pm/igniter) in your project:

```bash
mix slack_bot_ws.install
```

This creates a bot module, config stub, and supervision wiring. Skip to step 11 if you use this.

## 9. Define Your Bot Module

Create `lib/my_app/slack_bot.ex`:

```elixir
defmodule MyApp.SlackBot do
  use SlackBot, otp_app: :my_app

  # Respond to @mentions
  handle_event "app_mention", event, _ctx do
    SlackBot.push({"chat.postMessage", %{
      "channel" => event["channel"],
      "text" => "Hi <@#{event["user"]}>! I heard you."
    }})
  end
end
```

The `use SlackBot, otp_app: :my_app` macro:

- Injects the DSL (`handle_event`, `slash`, `middleware`)
- Tells SlackBot to read configuration from `:my_app` application env

## 10. Configure Tokens

In `config/config.exs`:

```elixir
config :my_app, MyApp.SlackBot,
  app_token: System.fetch_env!("SLACK_APP_TOKEN"),
  bot_token: System.fetch_env!("SLACK_BOT_TOKEN")
```

Or in `config/runtime.exs` if you prefer runtime configuration.

## 11. Supervise the Bot

In your application supervisor (`lib/my_app/application.ex`):

```elixir
def start(_type, _args) do
  children = [
    MyApp.SlackBot
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

## 12. Run

Set your environment variables and start:

```bash
export SLACK_APP_TOKEN="xapp-..."
export SLACK_BOT_TOKEN="xoxb-..."
iex -S mix
```

Invite your bot to a channel (`/invite @MyBot`) and mention it. You should see a reply.

## Adding a Slash Command Handler

If you created a `/demo` command in step 6, add a handler:

```elixir
defmodule MyApp.SlackBot do
  use SlackBot, otp_app: :my_app

  slash "/demo" do
    value :action

    handle payload, _ctx do
      action = payload["parsed"][:action] || "nothing"
      SlackBot.push({"chat.postMessage", %{
        "channel" => payload["channel_id"],
        "text" => "You asked me to: #{action}"
      }})
    end
  end

  handle_event "app_mention", event, _ctx do
    SlackBot.push({"chat.postMessage", %{
      "channel" => event["channel"],
      "text" => "Hi <@#{event["user"]}>!"
    }})
  end
end
```

Try `/demo deploy` in Slack. The handler receives `%{action: "deploy"}` in `payload["parsed"]`.

## What's Running Under the Hood

When your supervisor starts `MyApp.SlackBot`, SlackBot:

1. Reads configuration from `:my_app` app env and validates tokens
2. Starts an HTTP pool for Web API requests
3. Starts the ETS-backed cache and event buffer
4. Calls `apps.connections.open` to get a WebSocket URL
5. Opens the Socket Mode connection
6. Spawns supervised tasks for each incoming event

If the connection drops, SlackBot reconnects with exponential backoff. If Slack returns rate-limit headers, the rate limiter pauses outbound requests until the window passes.

## Next Steps

- [Slash Grammar Guide](slash_grammar.md) — build complex command parsers
- [Rate Limiting Guide](rate_limiting.md) — understand how tier-aware limiting works
- [Diagnostics Guide](diagnostics.md) — capture and replay events
- [Telemetry Guide](telemetry_dashboard.md) — integrate with LiveDashboard

The `examples/basic_bot/` directory contains a full working bot demonstrating middleware, advanced grammars, and diagnostics replay.
