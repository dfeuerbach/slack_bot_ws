defmodule SlackBot.Socket do
  @moduledoc false

  use WebSockex

  require Logger

  alias SlackBot.Diagnostics

  # Slack delivers several interactive payload types outside of the Events API.
  @interactive_types ~w(
    shortcut
    block_actions
    message_action
    workflow_step_edit
    workflow_step_execute
    block_suggestion
    view_submission
    view_closed
  )

  def start_link(url, opts) do
    manager = Keyword.fetch!(opts, :manager)
    config = Keyword.fetch!(opts, :config)

    state = %{
      manager: manager,
      config: config
    }

    WebSockex.start_link(url, __MODULE__, state, Keyword.drop(opts, [:manager, :config]))
  end

  @impl WebSockex
  def handle_connect(_conn, state) do
    send(state.manager, {:slackbot, :connected, self()})
    {:ok, state}
  end

  @impl WebSockex
  def handle_disconnect(connection_status, state) do
    send(state.manager, {:slackbot, :disconnected, connection_status})
    {:ok, state}
  end

  @impl WebSockex
  def handle_frame({:text, payload}, state) do
    case Jason.decode(payload) do
      {:ok, decoded} ->
        Logger.debug("[SlackBot.Socket] incoming frame #{inspect(decoded)}")
        handle_decoded(decoded, state)

      {:error, reason} ->
        log_decode_error(reason, payload, state)
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl WebSockex
  def handle_cast({:send, frame}, state) do
    {:reply, frame, state}
  end

  @impl WebSockex
  def terminate(reason, state) do
    send(state.manager, {:slackbot, :terminated, reason})
    :ok
  end

  defp handle_decoded(%{"type" => "hello"} = hello, state) do
    send(state.manager, {:slackbot, :hello, hello})
    {:ok, state}
  end

  defp handle_decoded(%{"type" => "disconnect"} = message, state) do
    send(state.manager, {:slackbot, :disconnect, message})
    {:ok, state}
  end

  defp handle_decoded(%{"type" => "slash_commands", "payload" => payload} = envelope, state) do
    ack(envelope, state.config)
    send(state.manager, {:slackbot, :slash_command, payload, envelope})
    {:ok, state}
  end

  defp handle_decoded(%{"payload" => payload} = envelope, state) do
    ack(envelope, state.config)

    case classify_payload(payload) do
      {:event, type, event} ->
        send(state.manager, {:slackbot, :event, type, event, envelope})

      {:slash, slash_payload} ->
        send(state.manager, {:slackbot, :slash_command, slash_payload, envelope})

      {:interactive, type, interactive_payload} ->
        send(state.manager, {:slackbot, :event, type, interactive_payload, envelope})

      {:unknown, unknown} ->
        send(state.manager, {:slackbot, :unknown, unknown})
    end

    {:ok, state}
  end

  defp handle_decoded(%{"type" => "events_api", "envelope_id" => _} = envelope, state) do
    ack(envelope, state.config)
    send(state.manager, {:slackbot, :events_api, envelope})
    {:ok, state}
  end

  defp handle_decoded(%{"type" => "ping"} = ping, state) do
    reply = Jason.encode!(%{type: "pong", id: ping["id"]})
    {:reply, {:text, reply}, state}
  end

  defp handle_decoded(%{"type" => "pong"} = pong, state) do
    send(state.manager, {:slackbot, :pong, pong})
    {:ok, state}
  end

  defp handle_decoded(message, state) do
    Logger.debug("[SlackBot.Socket] unhandled message #{inspect(message)}")
    {:ok, state}
  end

  defp ack(%{"envelope_id" => id} = envelope, config) when is_binary(id) do
    ack = Jason.encode!(%{envelope_id: id})

    Diagnostics.record(config, :outbound, %{
      type: "ack",
      payload: %{"envelope_id" => id},
      meta: %{envelope: envelope}
    })

    WebSockex.cast(self(), {:send, {:text, ack}})
  end

  defp ack(_, _), do: :ok

  defp log_decode_error(reason, payload, state) do
    Logger.warning(
      "[SlackBot.Socket] failed to decode payload: #{inspect(reason)} #{inspect(payload)}"
    )

    {:ok, state}
  end

  @doc false
  def classify_payload(%{"event" => event = %{"type" => type}}), do: {:event, type, event}
  def classify_payload(%{"type" => "slash_commands"} = payload), do: {:slash, payload}

  def classify_payload(%{"type" => type} = payload) when type in @interactive_types do
    {:interactive, type, payload}
  end

  def classify_payload(payload), do: {:unknown, payload}
end
