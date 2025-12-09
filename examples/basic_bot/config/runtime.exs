import Config

if config_env() != :test do
  config :basic_bot, BasicBot.SlackBot,
    app_token: System.fetch_env!("SLACK_APP_TOKEN"),
    bot_token: System.fetch_env!("SLACK_BOT_TOKEN")
end
