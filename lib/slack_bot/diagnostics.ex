defmodule SlackBot.Diagnostics do
  @moduledoc """
  Ring buffer for capturing and replaying Slack events.

  The diagnostics system records inbound and outbound Slack frames into a configurable
  ring buffer, allowing you to inspect recent traffic and replay events through your
  handlers—invaluable for reproducing production bugs locally.

  ## Why Use Diagnostics?

  - **Debug production issues** - Capture real payloads without external logging
  - **Reproduce bugs locally** - Replay production events in development
  - **Understand event structure** - Inspect Slack's payload format for new event types
  - **Test handler changes** - Replay captured events after code modifications

  ## Configuration

  Enable the diagnostics buffer in your bot config:

      config :my_app, MyApp.SlackBot,
        diagnostics: [
          enabled: true,
          buffer_size: 200  # Keeps most recent 200 events
        ]

  **Security note:** The buffer retains full Slack payloads including user messages.
  Only enable in environments where storing this data is acceptable, and clear the
  buffer when working with sensitive workspaces.

  ## Workflow: Capture, Inspect, Replay

  ### 1. Capture Events

  With diagnostics enabled, SlackBot automatically records all events. Run your bot
  and interact with it in Slack.

  ### 2. List Captured Events

      iex> SlackBot.Diagnostics.list(MyApp.SlackBot, limit: 5)
      [
        %{
          id: 12345,
          at: ~U[2025-12-01 10:30:00Z],
          direction: :inbound,
          type: "slash_commands",
          payload: %{"command" => "/deploy", ...}
        },
        ...
      ]

  Filter by event type:

      iex> SlackBot.Diagnostics.list(MyApp.SlackBot,
      ...>   types: ["message", "app_mention"])

  ### 3. Replay Events

  Replay captured events through your handlers to reproduce behavior:

      iex> SlackBot.Diagnostics.replay(MyApp.SlackBot,
      ...>   types: ["slash_commands"],
      ...>   since: ~U[2025-12-01 10:00:00Z])
      {:ok, 3}  # Replayed 3 events

  This re-runs the events through your current handler code, making it easy to:

  - Test fixes for reported bugs
  - Validate handler changes without hitting Slack
  - Understand handler behavior with real production data

  ### 4. Clear the Buffer

  After debugging, clear sensitive data:

      iex> SlackBot.Diagnostics.clear(MyApp.SlackBot)
      :ok

  ## Production Usage

  Keep diagnostics **disabled** in production by default. Enable temporarily when
  investigating issues, capture the relevant events, then disable and clear:

      # In production IEx session
      iex> Application.put_env(:my_app, MyApp.SlackBot,
      ...>   diagnostics: [enabled: true, buffer_size: 50])
      iex> # ... wait for events ...
      iex> events = SlackBot.Diagnostics.list(MyApp.SlackBot)
      iex> File.write!("events.json", Jason.encode!(events))
      iex> SlackBot.Diagnostics.clear(MyApp.SlackBot)

  ## See Also

  - [Diagnostics Guide](https://hexdocs.pm/slack_bot_ws/diagnostics.html)
  - `SlackBot.TelemetryStats` - For aggregated metrics without payload retention
  - Example app: `examples/basic_bot/`
  """

  alias SlackBot.Config
  alias SlackBot.Diagnostics.Server
  alias SlackBot.Telemetry

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
