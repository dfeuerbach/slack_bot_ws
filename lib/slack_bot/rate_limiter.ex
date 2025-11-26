defmodule SlackBot.RateLimiter do
  @moduledoc false

  use GenServer

  alias SlackBot.Config
  alias SlackBot.RateLimiter.Adapter
  alias SlackBot.RateLimiter.Adapters.ETS
  alias SlackBot.Telemetry

  @typedoc "Key used to scope rate limiting (channel, workspace, etc.)."
  @type key :: term()

  @channel_methods ~w(
    chat.postMessage
    chat.update
    chat.delete
    chat.scheduleMessage
    chat.postEphemeral
  )

  @doc """
  Returns a child specification for the configured rate limiter.

  When rate limiting is disabled (`rate_limiter: :none`), callers should
  skip attaching this child entirely.
  """
  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    {adapter, adapter_opts} = adapter_from_config(config)
    name = server_name(config.instance_name)

    %{
      id: name,
      start:
        {__MODULE__, :start_link,
         [[name: name, config: config, adapter: adapter, adapter_opts: adapter_opts]]},
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Wraps an HTTP call with per-key rate limiting when enabled.

  When `rate_limiter: :none`, `fun` is executed directly.
  """
  @spec around_request(Config.t(), String.t(), map(), (() -> term())) :: term()
  def around_request(%Config{rate_limiter: :none}, _method, _body, fun) when is_function(fun, 0) do
    fun.()
  end

  def around_request(%Config{} = config, method, body, fun) when is_function(fun, 0) do
    key = classify_request(method, body)
    server = server_name(config.instance_name)

    :ok =
      GenServer.call(
        server,
        {:before_request, key, method},
        Keyword.get(config.api_pool_opts, :request_timeout, :infinity)
      )

    try do
      result = fun.()
      GenServer.cast(server, {:after_request, key, method, result})
      result
    rescue
      exception ->
        GenServer.cast(server, {:after_request, key, method, {:exception, exception}})
        reraise exception, __STACKTRACE__
    end
  end

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    assert_behaviour!(adapter)

    {:ok, adapter_state} = adapter.init(config, adapter_opts)

    state = %{
      config: config,
      adapter: adapter,
      adapter_state: adapter_state,
      queues: %{},           # key => :queue.from_list([from, ...])
      in_flight: %{},        # key => non_neg_integer()
      release_timers: %{}    # key => reference()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:before_request, key, method}, from, state) do
    now = now_ms()
    {blocked_until, adapter_state} = state.adapter.blocked_until(state.adapter_state, key, now)

    in_flight = Map.get(state.in_flight, key, 0)
    queue = Map.get(state.queues, key, :queue.new())
    prev_queue_length = :queue.len(queue)

    decision =
      cond do
        is_integer(blocked_until) and blocked_until > now ->
          :queue

        in_flight > 0 ->
          :queue

        true ->
          :allow
      end

    case decision do
      :allow ->
        in_flight_map = Map.put(state.in_flight, key, in_flight + 1)

        emit_decision(state.config, key, method, :allow, 0, in_flight + 1)

        new_state = %{state | adapter_state: adapter_state, in_flight: in_flight_map}

        {:reply, :ok, new_state}

      :queue ->
        queue = :queue.in(from, queue)
        queues = Map.put(state.queues, key, queue)
        queue_length = :queue.len(queue)

        emit_decision(state.config, key, method, :queue, queue_length, in_flight)

        release_timers =
          if prev_queue_length == 0 and is_integer(blocked_until) and blocked_until > now do
            delay = max(blocked_until - now, 1)

            case Map.fetch(state.release_timers, key) do
              {:ok, _ref} ->
                state.release_timers

              :error ->
                ref = Process.send_after(self(), {:release_key, key}, delay)
                Map.put(state.release_timers, key, ref)
            end
          else
            state.release_timers
          end

        new_state = %{
          state
          | adapter_state: adapter_state,
            queues: queues,
            release_timers: release_timers
        }

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:after_request, key, method, result}, state) do
    now = now_ms()

    # Notify adapter of the result (rate-limit windows, etc.)
    {:ok, new_adapter_state} =
      state.adapter.record_result(state.adapter_state, key, now, unwrap_result(result))

    {in_flight, in_flight_map} =
      case Map.get(state.in_flight, key, 0) do
        0 -> {0, state.in_flight}
        n -> {n - 1, Map.put(state.in_flight, key, n - 1)}
      end

    queues = state.queues
    queue = Map.get(queues, key, :queue.new())

    # Emit a dedicated rate-limited event when we see Slack's ratelimited error.
    maybe_emit_rate_limited(state.config, key, method, result, now)

    {queues, in_flight_map, release_timers, latest_adapter_state} =
      case {in_flight, :queue.is_empty(queue)} do
        {0, false} ->
          {blocked_until, newest_adapter_state} =
            state.adapter.blocked_until(new_adapter_state, key, now)

          if is_integer(blocked_until) and blocked_until > now do
            delay = max(blocked_until - now, 1)

            release_timers =
              case Map.fetch(state.release_timers, key) do
                {:ok, _ref} ->
                  state.release_timers

                :error ->
                  ref = Process.send_after(self(), {:release_key, key}, delay)
                  Map.put(state.release_timers, key, ref)
              end

            {queues, in_flight_map, release_timers, newest_adapter_state}
          else
            {{:value, queued_from}, queue} = :queue.out(queue)
            queues = update_queue_map(queues, key, queue)

            emit_decision(state.config, key, method, :allow, :queue.len(queue), 1)

            GenServer.reply(queued_from, :ok)

            in_flight_map = Map.put(in_flight_map, key, 1)

            {queues, in_flight_map, state.release_timers, new_adapter_state}
          end

        _ ->
          {queues, in_flight_map, state.release_timers, new_adapter_state}
      end

    {:noreply,
     %{
       state
       | adapter_state: latest_adapter_state,
         queues: queues,
         in_flight: in_flight_map,
         release_timers: release_timers
     }}
  end

  @impl true
  def handle_info({:release_key, key}, state) do
    now = now_ms()
    {blocked_until, adapter_state} = state.adapter.blocked_until(state.adapter_state, key, now)
    queue = Map.get(state.queues, key, :queue.new())
    in_flight = Map.get(state.in_flight, key, 0)

    release_timers = Map.delete(state.release_timers, key)

    {queues, in_flight_map, release_timers} =
      cond do
        is_integer(blocked_until) and blocked_until > now ->
          # Still blocked; reschedule.
          delay = max(blocked_until - now, 1)
          ref = Process.send_after(self(), {:release_key, key}, delay)
          {state.queues, state.in_flight, Map.put(release_timers, key, ref)}

        in_flight > 0 or :queue.is_empty(queue) ->
          {state.queues, state.in_flight, release_timers}

        true ->
          {{:value, queued_from}, queue} = :queue.out(queue)
          queues = update_queue_map(state.queues, key, queue)

          emit_drain(state.config, key, 1)
          emit_decision(state.config, key, :unknown, :allow, :queue.len(queue), 1)

          GenServer.reply(queued_from, :ok)

          in_flight_map = Map.put(state.in_flight, key, 1)

          {queues, in_flight_map, release_timers}
      end

    {:noreply,
     %{
       state
       | adapter_state: adapter_state,
         queues: queues,
         in_flight: in_flight_map,
         release_timers: release_timers
     }}
  end

  defp unwrap_result({:exception, _} = result), do: result
  defp unwrap_result(result), do: result

  defp classify_request(method, body) when is_binary(method) and is_map(body) do
    cond do
      method in @channel_methods and is_binary(Map.get(body, "channel")) ->
        {:channel, Map.get(body, "channel")}

      method in @channel_methods and is_binary(Map.get(body, "channel_id")) ->
        {:channel, Map.get(body, "channel_id")}

      true ->
        :workspace
    end
  end

  defp server_name(instance_name) when is_atom(instance_name) do
    Module.concat(instance_name, :RateLimiter)
  end

  defp adapter_from_config(%Config{rate_limiter: {:adapter, module, opts}}), do: {module, opts}
  defp adapter_from_config(%Config{}), do: {ETS, []}

  defp update_queue_map(queues, key, queue) do
    if :queue.is_empty(queue) do
      Map.delete(queues, key)
    else
      Map.put(queues, key, queue)
    end
  end

  defp emit_decision(config, key, method, decision, queue_length, in_flight) do
    Telemetry.execute(
      config,
      [:rate_limiter, :decision],
      %{queue_length: normalize_int(queue_length), in_flight: in_flight},
      %{key: key, method: method, decision: decision}
    )
  end

  defp emit_drain(config, key, drained) do
    Telemetry.execute(
      config,
      [:rate_limiter, :drain],
      %{drained: drained},
      %{key: key, reason: :retry_after}
    )
  end

  defp maybe_emit_rate_limited(config, key, method, {:error, {:rate_limited, secs}}, now)
       when is_integer(secs) and secs > 0 do
    Telemetry.execute(
      config,
      [:api, :rate_limited],
      %{retry_after_ms: secs * 1_000, observed_at_ms: now},
      %{method: method, key: key}
    )
  end

  defp maybe_emit_rate_limited(_config, _key, _method, _result, _now), do: :ok

  defp assert_behaviour!(module) when is_atom(module) do
    behaviours =
      if Code.ensure_loaded?(module) do
        module.module_info(:attributes)
        |> Keyword.get(:behaviour, [])
      else
        []
      end

    unless Adapter in behaviours do
      raise ArgumentError,
            "#{inspect(module)} must implement SlackBot.RateLimiter.Adapter to be used as a rate limiter backend"
    end
  end

  defp normalize_int(:unknown), do: 0
  defp normalize_int(value) when is_integer(value), do: value

  defp now_ms, do: System.monotonic_time(:millisecond)
end
