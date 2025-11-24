defmodule BasicBot.SlackBot do
  @moduledoc """
  SlackBot entrypoint for the BasicBot example.

  This module wires the `BasicBot` router into a supervised Socket Mode connection
  using the `otp_app` pattern.
  """

  use SlackBot, otp_app: :basic_bot
end
