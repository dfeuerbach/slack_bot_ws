defmodule BasicBot.Application do
  @moduledoc """
  Minimal OTP application that boots SlackBot with the demo handler.
  """
  use Application

  def start(_type, _args) do
    children = [
      {SlackBot,
       name: BasicBot.SlackBot,
       module: BasicBot,
       app_token: System.fetch_env!("SLACK_APP_TOKEN"),
       bot_token: System.fetch_env!("SLACK_BOT_TOKEN"),
       telemetry_prefix: [:slackbot, :basic_bot],
       diagnostics: [enabled: true, buffer_size: 200],
       assigns: %{bot_user_id: System.fetch_env!("SLACK_BOT_USER_ID")}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BasicBot.Supervisor)
  end
end
