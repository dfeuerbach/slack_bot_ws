import Config

config :logger, level: :info

# Provide defaults for local development; override with real tokens via env vars.
config :basic_bot, :slack,
  app_token: System.get_env("SLACK_APP_TOKEN"),
  bot_token: System.get_env("SLACK_BOT_TOKEN"),
  bot_user_id: System.get_env("SLACK_BOT_USER_ID")
