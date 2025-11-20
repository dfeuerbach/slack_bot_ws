defmodule SlackBot.ConfigServer do
  @moduledoc false

  use GenServer

  alias SlackBot.Config

  @type option :: {:config, keyword()} | {:name, GenServer.name()}

  # Public API

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_opts = Keyword.get(opts, :config, [])

    GenServer.start_link(__MODULE__, config_opts, name: name)
  end

  @spec config(GenServer.server()) :: Config.t()
  def config(server \\ __MODULE__) do
    GenServer.call(server, :config)
  end

  # Callbacks

  @impl true
  def init(opts) do
    case Config.build(opts) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:stop, {:invalid_config, reason}}
    end
  end

  @impl true
  def handle_call(:config, _from, config) do
    {:reply, config, config}
  end
end
