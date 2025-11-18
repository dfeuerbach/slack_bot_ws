defmodule SlackBot.Diagnostics do
  @moduledoc """
  Diagnostics buffer and replay helpers.

  Configure via `%SlackBot.Config{diagnostics: [enabled: true, buffer_size: 200]}`.
  When enabled, SlackBot records inbound/outbound frames so you can inspect or replay
  recent traffic from an IEx session.
  """

  alias SlackBot.Config
  alias SlackBot.Telemetry
  alias SlackBot.Diagnostics.Server

  @type direction :: :inbound | :outbound
  @type entry :: %{
          required(:id) => integer(),
          required(:at) => DateTime.t(),
          required(:direction) => direction(),
          required(:type) => String.t(),
          required(:payload) => map(),
          optional(:meta) => map()
        }

  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    name = server_name(config.instance_name)
    %{enabled: enabled, buffer_size: size} = diagnostics_config(config)

    %{
      id: name,
      start: {Server, :start_link, [[name: name, buffer_size: size, enabled: enabled]]},
      type: :worker
    }
  end

  @doc false
  def record(%Config{} = config, direction, attrs)
      when direction in [:inbound, :outbound] and is_map(attrs) do
    %{enabled: enabled} = diagnostics_config(config)

    if enabled do
      entry =
        attrs
        |> Map.merge(%{
          id: System.unique_integer([:positive]),
          at: DateTime.utc_now(),
          direction: direction
        })

      server_name(config.instance_name)
      |> GenServer.cast({:record, entry})

      Telemetry.execute(config, [:diagnostics, :record], %{count: 1}, %{direction: direction})
    end

    :ok
  end

  @doc """
  Returns buffered entries for the given SlackBot instance.
  """
  @spec list(GenServer.server() | Config.t(), keyword()) :: [entry()]
  def list(server_or_config \\ SlackBot, opts \\ [])

  def list(%Config{} = config, opts), do: do_list(config, opts)

  def list(server, opts) do
    server
    |> SlackBot.config()
    |> do_list(opts)
  end

  @doc """
  Clears the buffer for the given instance.
  """
  @spec clear(GenServer.server() | Config.t()) :: :ok
  def clear(server_or_config \\ SlackBot)

  def clear(%Config{instance_name: instance}) do
    server_name(instance)
    |> GenServer.cast(:clear)
  end

  def clear(server) do
    server
    |> SlackBot.config()
    |> clear()
  end

  @doc """
  Replays buffered inbound events back through `SlackBot.emit/2`.

  Returns `{:ok, count}` where `count` is the number of events replayed.
  """
  @spec replay(GenServer.server() | Config.t(), keyword()) :: {:ok, non_neg_integer()}
  def replay(server_or_config \\ SlackBot, opts \\ [])

  def replay(%Config{} = config, opts) do
    dispatch = Keyword.get(opts, :dispatch, fn _entry -> :ok end)
    do_replay(config, opts, dispatch)
  end

  def replay(server, opts) do
    config = SlackBot.config(server)

    dispatch =
      Keyword.get(opts, :dispatch, fn %{type: type, payload: payload} ->
        SlackBot.emit(server, {type, payload})
      end)

    do_replay(config, opts, dispatch)
  end

  defp server_name(instance_name) when is_atom(instance_name) do
    Module.concat(instance_name, :Diagnostics)
  end

  defp diagnostics_config(%{diagnostics: value}) when is_map(value), do: value
  defp diagnostics_config(_), do: %{enabled: false, buffer_size: 200}

  defp do_list(%Config{instance_name: instance}, opts) do
    server_name(instance)
    |> GenServer.call({:list, Keyword.delete(opts, :dispatch)})
  end

  defp do_replay(%Config{instance_name: instance} = config, opts, dispatch_fun) do
    filter_opts =
      opts
      |> Keyword.delete(:dispatch)
      |> Keyword.put(:direction, :inbound)

    entries =
      server_name(instance)
      |> GenServer.call({:replay_source, filter_opts})

    Enum.each(entries, dispatch_fun)

    Telemetry.execute(
      config,
      [:diagnostics, :replay],
      %{count: length(entries)},
      %{filters: Map.new(filter_opts)}
    )

    {:ok, length(entries)}
  end
end
