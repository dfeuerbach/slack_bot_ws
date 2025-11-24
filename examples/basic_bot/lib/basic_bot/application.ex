defmodule BasicBot.Application do
  @moduledoc """
  Minimal OTP application that boots SlackBot with the demo router.
  """
  use Application

  def start(_type, _args) do
    children = [
      BasicBot.SlackBot
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BasicBot.Supervisor)
  end
end
