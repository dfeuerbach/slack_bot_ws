defmodule SlackBot.ConnectionManager do
  @moduledoc """
  Maintains the Slack Socket Mode connection, reconnection strategy, and event dispatch.
  """

  use GenServer

  require Logger

  alias SlackBot.Config
  alias SlackBot.ConfigServer
  alias SlackBot.EventBuffer
  alias SlackBot.Cache

  @type option ::
          {:name, GenServer.name()}
          | {:config_server, GenServer.server()}
          | {:task_supervisor, atom()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec emit(GenServer.server(), String.t(), map()) :: :ok
  def emit(server, type, payload) do
    GenServer.cast(server, {:emit, type, payload, %{origin: :emit}})
  end

  @impl true
  def init(opts) do
    config_server = Keyword.fetch!(opts, :config_server)
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
    config = ConfigServer.config(config_server)

    state = %{
      config_server: config_server,
      config: config,
      task_supervisor: task_supervisor,
      transport_pid: nil,
      transport_ref: nil,
      attempt: 0,
      last_activity: now_ms(),
      heartbeat_ref: nil
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    connect(state)
  end

  def handle_info(:heartbeat, state) do
    schedule_heartbeat(state.config)

    cond do
      is_nil(state.transport_pid) ->
        {:noreply, state}

      now_ms() - state.last_activity > state.config.heartbeat_ms + state.config.ping_timeout_ms ->
        Logger.warning("[SlackBot] heartbeat timeout, restarting connection")
        reset_transport(state, :heartbeat_timeout)

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:slackbot, :connected, pid}, state) do
    Logger.debug("[SlackBot] connected via #{inspect(pid)}")

    {:noreply,
     %{state | transport_pid: pid, transport_ref: Process.monitor(pid), last_activity: now_ms()}}
  end

  def handle_info({:slackbot, :disconnected, reason}, state) do
    Logger.warning("[SlackBot] disconnected: #{inspect(reason)}")
    reset_transport(state, reason)
  end

  def handle_info({:slackbot, :terminated, reason}, state) do
    Logger.warning("[SlackBot] transport terminated: #{inspect(reason)}")
    reset_transport(state, reason)
  end

  def handle_info({:slackbot, :event, type, event, envelope}, state) do
    dispatch_event(type, event, envelope, state)
  end

  def handle_info({:slackbot, :slash_command, payload, envelope}, state) do
    dispatch_event("slash_commands", payload, envelope, state)
  end

  def handle_info({:slackbot, :unknown, payload}, state) do
    Logger.debug("[SlackBot] unknown payload #{inspect(payload)}")
    {:noreply, state}
  end

  def handle_info({:slackbot, :hello, _hello}, state) do
    {:noreply, %{state | last_activity: now_ms()}}
  end

  def handle_info({:slackbot, :pong, _pong}, state) do
    {:noreply, %{state | last_activity: now_ms()}}
  end

  def handle_info({:slackbot, :synthetic, type, payload, meta}, state) do
    dispatch_event(type, payload, meta, state)
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{transport_ref: ref, transport_pid: pid} = state
      ) do
    Logger.warning("[SlackBot] transport down #{inspect(reason)}")
    reset_transport(state, reason)
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:emit, type, payload, meta}, state) do
    dispatch_event(type, payload, meta, state)
  end

  defp connect(state) do
    config = ConfigServer.config(state.config_server)
    state = %{state | config: config}

    case config.http_client.apps_connections_open(config.app_token) do
      {:ok, url} ->
        start_transport(url, state)

      {:rate_limited, secs} ->
        Logger.warning("[SlackBot] rate limited, retrying in #{secs}s")
        schedule_reconnect(state, secs * 1_000)

      {:error, reason} ->
        Logger.warning("[SlackBot] failed to open connection #{inspect(reason)}")
        schedule_reconnect(state, backoff_delay(state))
    end
  end

  defp start_transport(url, state) do
    opts =
      state.config.transport_opts
      |> Keyword.put(:manager, self())
      |> Keyword.put(:config, state.config)

    case state.config.transport.start_link(url, opts) do
      {:ok, pid} ->
        Logger.info("[SlackBot] connected to Slack socket")
        schedule_heartbeat(state.config)

        {:noreply,
         %{
           state
           | transport_pid: pid,
             transport_ref: Process.monitor(pid),
             attempt: 0,
             last_activity: now_ms()
         }}

      {:error, reason} ->
        Logger.warning("[SlackBot] transport start failed #{inspect(reason)}")
        schedule_reconnect(state, backoff_delay(state))
    end
  end

  defp reset_transport(state, _reason) do
    if state.transport_pid do
      Process.demonitor(state.transport_ref, [:flush])
    end

    send(self(), :connect)
    {:noreply, %{state | transport_pid: nil, transport_ref: nil}}
  end

  defp schedule_reconnect(state, delay_ms) do
    next_attempt = state.attempt + 1

    if state.config.backoff.max_attempts != :infinity and
         next_attempt > state.config.backoff.max_attempts do
      {:stop, :max_retries, state}
    else
      Process.send_after(self(), :connect, delay_ms)
      {:noreply, %{state | attempt: next_attempt}}
    end
  end

  defp schedule_heartbeat(config) do
    Process.send_after(self(), :heartbeat, config.heartbeat_ms)
  end

  defp dispatch_event(type, payload, envelope, state) do
    key = envelope_id(envelope)

    if key && EventBuffer.seen?(state.config, key) do
      Logger.debug("[SlackBot] duplicate envelope #{key}, skipping")
      {:noreply, state}
    else
      EventBuffer.record(state.config, key, envelope)
      maybe_update_cache(type, payload, state.config)

      Task.Supervisor.start_child(state.task_supervisor, fn ->
        invoke_handler(state.config, type, payload, envelope)
      end)

      {:noreply, %{state | last_activity: now_ms()}}
    end
  end

  defp invoke_handler(%Config{} = config, type, payload, envelope) do
    context = %{
      config: config,
      envelope: envelope,
      assigns: config.assigns
    }

    try do
      config.module.handle_event(type, payload, context)
    rescue
      exception ->
        Logger.error(Exception.format(:error, exception, __STACKTRACE__))
        :error
    end
  end

  defp envelope_id(%{"envelope_id" => id}), do: id
  defp envelope_id(_), do: nil

  defp maybe_update_cache(
         "member_joined_channel",
         %{"channel" => channel, "user" => user},
         config
       ) do
    if bot_user?(config, user), do: Cache.join_channel(config, channel)
  end

  defp maybe_update_cache("channel_left", %{"channel" => channel, "user" => user}, config) do
    if bot_user?(config, user), do: Cache.leave_channel(config, channel)
  end

  defp maybe_update_cache("channel_joined", %{"channel" => %{"id" => channel}}, config) do
    Cache.join_channel(config, channel)
  end

  defp maybe_update_cache("team_join", %{"user" => user}, config) when is_map(user) do
    Cache.put_user(config, user)
  end

  defp maybe_update_cache("user_change", %{"user" => user}, config) when is_map(user) do
    Cache.put_user(config, user)
  end

  defp maybe_update_cache(_type, _payload, _config), do: :ok

  defp bot_user?(%{assigns: %{bot_user_id: bot_user_id}}, user_id) when is_binary(bot_user_id),
    do: bot_user_id == user_id

  defp bot_user?(_, _), do: false

  defp backoff_delay(state) do
    attempt = max(state.attempt, 1)
    min_ms = state.config.backoff.min_ms
    max_ms = state.config.backoff.max_ms
    trunc(min(max_ms, min_ms * :math.pow(2, attempt - 1)))
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
