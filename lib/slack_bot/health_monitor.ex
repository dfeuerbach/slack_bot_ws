defmodule SlackBot.HealthMonitor do
  @moduledoc false

  # Periodic health checks against Slack's Web API.
  #
  # This GenServer runs per SlackBot instance and issues a lightweight
  # `auth.test` call on a configurable interval. When Slack (or the network)
  # misbehaves, it emits Telemetry and nudges the instance's connection
  # manager to reconnect using the existing backoff logic.
  #
  # The monitor intentionally keeps a very small surface area:
  #
  #   * It never manipulates sockets directly.
  #   * It always routes HTTP through the configured `http_client`.
  #   * It guarantees at most one in-flight ping by scheduling the next
  #     `:ping` only after the current one completes.
  #
  use GenServer

  require Logger

  alias SlackBot.Config
  alias SlackBot.ConfigServer
  alias SlackBot.Telemetry

  @type option ::
          {:name, GenServer.name()}
          | {:config_server, GenServer.server()}
          | {:connection_manager, GenServer.server()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    config_server = Keyword.fetch!(opts, :config_server)
    connection_manager = Keyword.fetch!(opts, :connection_manager)

    %Config{health_check: health} = config = ConfigServer.config(config_server)

    state = %{
      config_server: config_server,
      connection_manager: connection_manager,
      interval_ms: health.interval_ms,
      next_delay_ms: health.interval_ms
    }

    if health.enabled do
      schedule_ping(state.interval_ms)
    else
      Telemetry.execute(config, [:healthcheck, :disabled], %{count: 1}, %{})
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:ping, state) do
    config = ConfigServer.config(state.config_server)

    start = System.monotonic_time()
    result = config.http_client.post(config, "auth.test", %{})
    duration = System.monotonic_time() - start

    {next_delay_ms, state} = handle_ping_result(result, duration, state, config)

    schedule_ping(next_delay_ms)

    {:noreply, %{state | next_delay_ms: next_delay_ms}}
  end

  defp schedule_ping(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :ping, interval_ms)
  end

  defp schedule_ping(_), do: :ok

  defp handle_ping_result({:ok, %{"ok" => true}}, duration, state, %Config{} = config) do
    Logger.debug("[SlackBot] healthcheck ping status=:ok")

    Telemetry.execute(config, [:healthcheck, :ping], %{duration: duration}, %{status: :ok})
    {state.interval_ms, state}
  end

  defp handle_ping_result({:error, {:rate_limited, secs}}, duration, state, %Config{} = config)
       when is_integer(secs) and secs > 0 do
    delay_ms = max(secs * 1_000, state.interval_ms)

    Logger.debug(
      "[SlackBot] healthcheck ping status=:rate_limited delay_ms=#{delay_ms}"
    )

    Telemetry.execute(
      config,
      [:healthcheck, :ping],
      %{duration: duration, delay_ms: delay_ms},
      %{status: :rate_limited}
    )

    {delay_ms, state}
  end

  defp handle_ping_result({:error, {:slack_error, reason}}, duration, state, %Config{} = config)
       when reason in ["invalid_auth", "account_inactive", "not_authed"] do
    Logger.debug(
      "[SlackBot] healthcheck ping status=:fatal reason=#{inspect(reason)}"
    )

    Telemetry.execute(
      config,
      [:healthcheck, :ping],
      %{duration: duration},
      %{status: :fatal, reason: reason}
    )

    # Back off aggressively but keep a path for recovery if config changes.
    {state.interval_ms * 10, state}
  end

  defp handle_ping_result({:error, reason}, duration, state, %Config{} = config) do
    Logger.debug(
      "[SlackBot] healthcheck ping status=:error reason=#{inspect(reason)}"
    )
    Telemetry.execute(
      config,
      [:healthcheck, :ping],
      %{duration: duration},
      %{status: :error, reason: reason}
    )

    send(state.connection_manager, {:slackbot, :healthcheck_failed, reason})

    # Mild backoff for the next ping to avoid hammering an unhealthy network.
    {max(15_000, state.interval_ms), state}
  end

  defp handle_ping_result(other, duration, state, %Config{} = config) do
    Logger.debug(
      "[SlackBot] healthcheck ping status=:unknown result=#{inspect(other)}"
    )

    Telemetry.execute(
      config,
      [:healthcheck, :ping],
      %{duration: duration},
      %{status: :unknown, result: other}
    )

    {state.interval_ms, state}
  end
end
