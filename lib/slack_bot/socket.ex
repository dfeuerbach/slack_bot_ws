defmodule SlackBot.Socket do
  @moduledoc false

  use WebSockex

  require Logger

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
      {:ok, decoded} -> handle_decoded(decoded, state)
      {:error, reason} -> log_decode_error(reason, payload, state)
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

  defp handle_decoded(%{"payload" => payload} = envelope, state) do
    ack(envelope)

    case payload do
      %{"event" => event = %{"type" => type}} ->
        send(state.manager, {:slackbot, :event, type, event, envelope})

      %{"type" => "slash_commands"} ->
        send(state.manager, {:slackbot, :slash_command, payload, envelope})

      _ ->
        send(state.manager, {:slackbot, :unknown, payload})
    end

    {:ok, state}
  end

  defp handle_decoded(%{"type" => "events_api", "envelope_id" => _} = envelope, state) do
    ack(envelope)
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

  defp ack(%{"envelope_id" => id}) when is_binary(id) do
    ack = Jason.encode!(%{envelope_id: id})
    WebSockex.cast(self(), {:send, {:text, ack}})
  end

  defp ack(_), do: :ok

  defp log_decode_error(reason, payload, state) do
    Logger.warning(
      "[SlackBot.Socket] failed to decode payload: #{inspect(reason)} #{inspect(payload)}"
    )

    {:ok, state}
  end
end
