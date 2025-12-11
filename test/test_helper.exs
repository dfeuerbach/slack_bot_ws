ExUnit.start()

defmodule SlackBot.TestHandler do
  @moduledoc false

  def handle_event(type, payload, ctx) do
    if test_pid = ctx.assigns[:test_pid] do
      send(test_pid, {:handled, type, payload, ctx})
    end

    cond do
      truthy?(payload["raise"]) ->
        raise "forced-test-error"

      truthy?(payload["handler_error"]) ->
        {:error, :forced_error}

      truthy?(payload["handler_halt"]) ->
        {:halt, :forced_halt}

      true ->
        :ok
    end
  end

  defp truthy?(value), do: value in [true, "true", 1]
end

defmodule SlackBot.ConnectionTestHelpers do
  @moduledoc """
  Test-only helpers shared by connection manager suites.

  The SlackBot connection lifecycle runs asynchronously: reconnects happen on a
  backoff schedule, and telemetry events may lag behind transport notifications.
  These helpers give each test its own registered process names, and wrap the
  longer mailbox waits we expect in a Socket Mode reconnect path.
  """

  @receive_timeout 1_000

  @doc """
  Returns a unique atom name based on the provided prefix.
  """
  @spec unique_name(atom() | String.t()) :: atom()
  def unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  @doc """
  Waits for SlackBot.TestTransport to publish a new transport pid, ensuring we
  do not accidentally re-use the original pid during reconnect assertions.
  """
  @spec assert_transport_restart(pid(), timeout()) :: pid()
  def assert_transport_restart(old_pid, timeout \\ @receive_timeout) do
    deadline = now_ms() + timeout
    wait_for_transport(deadline, old_pid)
  end

  defp wait_for_transport(deadline, old_pid) do
    remaining = time_left(deadline)

    receive do
      {:test_transport, new_pid} when is_pid(new_pid) and new_pid != old_pid ->
        new_pid

      _other ->
        wait_for_transport(deadline, old_pid)
    after
      remaining ->
        ExUnit.Assertions.flunk("""
        expected SlackBot.TestTransport to emit a new pid different from #{inspect(old_pid)}
        """)
    end
  end

  @doc """
  Asserts that a specific connection-state telemetry event was emitted, ignoring
  earlier events (e.g. `:connected`) until the expected state arrives.
  """
  @spec assert_conn_state(:connected | :disconnect, timeout()) ::
          {map(), %{state: atom()}}
  def assert_conn_state(state, timeout \\ @receive_timeout) do
    deadline = now_ms() + timeout
    wait_for_conn_state(deadline, state)
  end

  defp wait_for_conn_state(deadline, state) do
    remaining = time_left(deadline)

    receive do
      {:telemetry_event, [:slackbot, :connection, :state], measurements,
       %{state: ^state} = metadata} ->
        {measurements, metadata}

      _other ->
        wait_for_conn_state(deadline, state)
    after
      remaining ->
        ExUnit.Assertions.flunk("""
        expected [:slackbot, :connection, :state] telemetry with state #{inspect(state)}
        """)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp time_left(deadline) do
    max(deadline - now_ms(), 0)
  end
end
