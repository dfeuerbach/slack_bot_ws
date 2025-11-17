defmodule SlackBot.RuntimeSupervisor do
  @moduledoc """
  Placeholder supervisor for runtime processes (connection manager, caches, etc.).

  Later phases will populate this supervisor with the concrete workers that manage
  the Slack socket connection, event buffer, caches, and diagnostics.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Supervisor.init([], strategy: :rest_for_one)
  end
end
