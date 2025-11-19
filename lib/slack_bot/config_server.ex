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

  @spec reload(keyword(), GenServer.server()) :: :ok | {:error, term()}
  def reload(overrides, server \\ __MODULE__) do
    GenServer.call(server, {:reload, overrides})
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

  def handle_call({:reload, overrides}, _from, config) do
    merged_opts =
      config
      |> config_to_opts()
      |> Keyword.merge(overrides)

    case Config.build(merged_opts) do
      {:ok, new_config} -> {:reply, :ok, new_config}
      {:error, reason} -> {:reply, {:error, reason}, config}
    end
  end

  defp config_to_opts(%Config{} = config) do
    config
    |> Map.from_struct()
    |> Map.delete(:__struct__)
    |> Enum.into([])
  end
end
