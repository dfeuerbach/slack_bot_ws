import Config

config :logger, level: :info

config :basic_bot, BasicBot.SlackBot,
  app_token: System.fetch_env!("SLACK_APP_TOKEN"),
  bot_token: System.fetch_env!("SLACK_BOT_TOKEN"),
  telemetry_prefix: [:slackbot, :basic_bot],
  diagnostics: [enabled: true, buffer_size: 200],
  assigns: %{bot_user_id: System.fetch_env!("SLACK_BOT_USER_ID")},
  block_builder: {:blockbox, []}
