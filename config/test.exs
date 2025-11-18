import Config

config :slack_bot_ws, SlackBot,
  app_token: "xapp-test-token",
  bot_token: "xoxb-test-token",
  module: SlackBot.TestHandler,
  telemetry_prefix: [:slackbot, :test]

config :logger, level: :warning
