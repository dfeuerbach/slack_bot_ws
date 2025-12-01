defmodule BasicBot.SlackBot do
  @moduledoc """
  SlackBot entrypoint for the BasicBot example.

  This module wires the `BasicBot` router into a supervised Socket Mode connection
  using the `otp_app` pattern. It demonstrates the recommended way to integrate
  SlackBot into your application.

  ## Configuration

  BasicBot reads tokens and settings from `config/config.exs`:

      config :basic_bot, BasicBot.SlackBot,
        app_token: System.fetch_env!("SLACK_APP_TOKEN"),
        bot_token: System.fetch_env!("SLACK_BOT_TOKEN"),
        telemetry_stats: [enabled: true]

  ## Supervision

  The module is supervised by `BasicBot.Application`:

      children = [
        BasicBot.SlackBot
      ]

  When you `use SlackBot, otp_app: :my_app`, the module automatically implements
  `child_spec/1` that merges runtime options with application config, making it
  trivial to add to your supervision tree.

  ## See Also

  - `BasicBot` - The router defining event handlers and slash commands
  - `BasicBot.Application` - How to supervise the bot
  - `SlackBot` - Main documentation and API reference
  """

  use SlackBot, otp_app: :basic_bot
end
