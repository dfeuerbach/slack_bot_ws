defmodule BasicBot.Application do
  @moduledoc """
  Minimal OTP application demonstrating how to supervise a SlackBot instance.

  This module is part of the BasicBot example included with SlackBot. It shows
  the simplest possible supervision setup: just add your bot module to the
  children list and SlackBot handles the rest.

  ## Running the Example

  The complete BasicBot example lives in the SlackBot repository at
  [`examples/basic_bot/`](https://github.com/dfeuerbach/slack_bot_ws/tree/master/examples/basic_bot).

  To try it yourself:

  1. Clone the repository:

      ```bash
      git clone https://github.com/dfeuerbach/slack_bot_ws.git
      cd slack_bot_ws/examples/basic_bot
      ```

  2. Set your Slack tokens:

      ```bash
      export SLACK_APP_TOKEN=xapp-...
      export SLACK_BOT_TOKEN=xoxb-...
      ```

  3. Run the bot:

      ```bash
      mix deps.get
      iex -S mix
      ```

  4. Try slash commands in your Slack workspace:

      ```
      /demo help
      /demo list short fleet tag alpha
      /demo blocks
      /demo telemetry
      ```

  ## What BasicBot Demonstrates

  The example showcases:

  - Slash command grammar DSL with optional/repeat segments
  - Event handlers (`app_mention`, `block_actions`)
  - Middleware logging
  - Diagnostics capture and replay
  - Auto-ack strategies (`:silent`, `:ephemeral`)
  - BlockBox integration (when configured)
  - Cache queries (users, channels)
  - Telemetry snapshots
  - Async Web API calls

  ## See Also

  - `BasicBot` - The router module defining events and slash commands
  - [Getting Started Guide](https://hexdocs.pm/slack_bot_ws/getting_started.html)
  - [Slash Grammar Guide](https://hexdocs.pm/slack_bot_ws/slash_grammar.html)
  """
  use Application

  @doc """
  Boots the BasicBot supervision tree.

  The application supervises a single `BasicBot.SlackBot` child using
  `:one_for_one`, mirroring the minimum setup most real bots start with.

  ## Return value

  The return value mirrors `Supervisor.start_link/2`. In typical cases it is
  `{:ok, pid}`, but the supervisor may also return `{:error, reason}` when the
  tree fails to start.

  ## Examples

      iex> BasicBot.Application.start(:normal, [])
      {:ok, #PID<0.200.0>}
  """
  @spec start(Application.start_type(), term()) :: Supervisor.on_start()
  def start(_type, _args) do
    children = [
      BasicBot.SlackBot
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BasicBot.Supervisor)
  end
end
