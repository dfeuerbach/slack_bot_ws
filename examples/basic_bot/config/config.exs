import Config

config :logger, level: :debug

config :basic_bot, BasicBot.SlackBot,
  app_token: "xapp-placeholder",
  bot_token: "xoxb-placeholder",
  module: BasicBot,
  telemetry_prefix: [:slackbot, :basic_bot],
  telemetry_stats: [
    enabled: true,
    flush_interval_ms: 10_000,
    ttl_ms: 300_000
  ],
  log_level: :debug,
  diagnostics: [enabled: true, buffer_size: 200],
  block_builder: {:blockbox, []}
