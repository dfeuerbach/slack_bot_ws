defmodule SlackBot.RateLimiter do
  @moduledoc false

  use GenServer

  alias SlackBot.Config
  alias SlackBot.RateLimiter.Adapter
  alias SlackBot.RateLimiter.Adapters.ETS
  alias SlackBot.RateLimiter.Queue
  alias SlackBot.RateLimiter.Timer
  alias SlackBot.Telemetry

  alias __MODULE__.CallbackCtx

  defmodule CallbackCtx do
    @moduledoc false

    defstruct [
      :key,
      :method,
      :queue,
      :blocked_until,
      :now,
      :in_flight,
      :timer_info,
      :prev_queue_length
    ]
  end

  @typedoc "Key used to scope rate limiting (channel, workspace, etc.)."
  @type key :: term()

  @channel_methods ~w(
    chat.postMessage
    chat.update
    chat.delete
    chat.scheduleMessage
    chat.postEphemeral
  )

  defguardp future_blocked(value, now) when is_integer(value) and value > now

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
  @spec around_request(Config.t(), String.t(), map(), (-> term())) :: term()
  def around_request(%Config{rate_limiter: :none}, _method, _body, fun)
      when is_function(fun, 0) do
    fun.()
  end

  def around_request(%Config{} = config, method, body, fun) when is_function(fun, 0) do
    key = classify_request(method, body)
    server = server_name(config.instance_name)

    :ok = GenServer.call(server, {:before_request, key, method}, :infinity)

    try do
      fun.()
    rescue
      exception ->
        GenServer.cast(server, {:after_request, key, method, {:exception, exception}})
        reraise exception, __STACKTRACE__
    else
      result ->
        GenServer.cast(server, {:after_request, key, method, result})
        result
    catch
      kind, value ->
        GenServer.cast(server, {:after_request, key, method, {kind, value}})
        :erlang.raise(kind, value, __STACKTRACE__)
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
      # key => :queue.from_list([from, ...])
      queues: %{},
      # key => non_neg_integer()
      in_flight: %{},
      # key => %{ref: reference(), delay_ms: integer(), method: term()}
      release_timers: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:before_request, key, method}, from, state) do
    now = now_ms()
    {blocked_until, adapter_state} = state.adapter.blocked_until(state.adapter_state, key, now)

    in_flight = Map.get(state.in_flight, key, 0)
    queue = Map.get(state.queues, key, Queue.new())
    prev_queue_length = Queue.size(queue)

    case before_request_decision(blocked_until, now, in_flight) do
      :allow ->
        allow_before_request(state, key, method, in_flight, adapter_state)

      :queue ->
        ctx =
          %CallbackCtx{
            key: key,
            method: method,
            queue: queue,
            blocked_until: blocked_until,
            now: now,
            in_flight: in_flight,
            prev_queue_length: prev_queue_length
          }

        queue_before_request(state, from, ctx, adapter_state)
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
    queue = Map.get(queues, key, Queue.new())

    # Emit a dedicated rate-limited event when we see Slack's ratelimited error.
    maybe_emit_rate_limited(state.config, key, method, result, now)

    updated_state = %{
      state
      | adapter_state: new_adapter_state,
        in_flight: in_flight_map,
        queues: queues
    }

    {:noreply, finalize_after_request(updated_state, key, method, queue, in_flight, now)}
  end

  @impl true
  def handle_info({:release_key, key}, state) do
    now = now_ms()
    {blocked_until, adapter_state} = state.adapter.blocked_until(state.adapter_state, key, now)
    queue = Map.get(state.queues, key, Queue.new())
    in_flight = Map.get(state.in_flight, key, 0)

    {timer_info, release_timers} = Map.pop(state.release_timers, key)

    ctx = %CallbackCtx{
      key: key,
      method: Timer.method(timer_info),
      queue: queue,
      blocked_until: blocked_until,
      now: now,
      in_flight: in_flight,
      timer_info: timer_info
    }

    new_state =
      state
      |> Map.put(:adapter_state, adapter_state)
      |> Map.put(:release_timers, release_timers)
      |> handle_release_event(ctx)

    {:noreply, new_state}
  end

  defp unwrap_result({:exception, _} = result), do: result
  defp unwrap_result(result), do: result

  defp classify_request(method, body) when is_binary(method) and is_map(body) do
    channel =
      Map.get(body, "channel") ||
        Map.get(body, :channel) ||
        Map.get(body, "channel_id") ||
        Map.get(body, :channel_id)

    if method in @channel_methods and is_binary(channel) do
      {:channel, channel}
    else
      :workspace
    end
  end

  defp server_name(instance_name) when is_atom(instance_name) do
    Module.concat(instance_name, :RateLimiter)
  end

  defp adapter_from_config(%Config{rate_limiter: {:adapter, module, opts}}), do: {module, opts}
  defp adapter_from_config(%Config{}), do: {ETS, []}

  defp update_queue_map(queues, key, queue) do
    if Queue.empty?(queue) do
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

  defp emit_blocked(config, key, method, delay_ms) do
    Telemetry.execute(
      config,
      [:rate_limiter, :blocked],
      %{delay_ms: delay_ms},
      %{key: key, method: method}
    )
  end

  defp emit_drain(config, key, drained, opts) do
    measurements =
      %{drained: drained}
      |> maybe_put_measurement(:delay_ms, opts[:delay_ms])

    Telemetry.execute(
      config,
      [:rate_limiter, :drain],
      measurements,
      %{key: key, reason: Keyword.get(opts, :reason, :retry_after)}
    )
  end

  defp maybe_put_measurement(map, _key, nil), do: map

  defp maybe_put_measurement(map, key, value) when is_integer(value) and value >= 0,
    do: Map.put(map, key, value)

  defp maybe_put_measurement(map, _key, _value), do: map

  defp before_request_decision(blocked_until, now, _in_flight)
       when future_blocked(blocked_until, now),
       do: :queue

  defp before_request_decision(_blocked_until, _now, in_flight) when in_flight > 0, do: :queue

  defp before_request_decision(_blocked_until, _now, _in_flight), do: :allow

  defp allow_before_request(state, key, method, in_flight, adapter_state) do
    in_flight_map = Map.put(state.in_flight, key, in_flight + 1)
    emit_decision(state.config, key, method, :allow, 0, in_flight + 1)
    {:reply, :ok, %{state | adapter_state: adapter_state, in_flight: in_flight_map}}
  end

  defp queue_before_request(state, from, %CallbackCtx{} = ctx, adapter_state) do
    queue = Queue.push(ctx.queue, {from, ctx.method})
    queues = Map.put(state.queues, ctx.key, queue)
    queue_length = Queue.size(queue)

    emit_decision(state.config, ctx.key, ctx.method, :queue, queue_length, ctx.in_flight)

    release_timers =
      maybe_schedule_block_timer(
        state,
        %CallbackCtx{ctx | queue: queue}
      )

    new_state = %{
      state
      | adapter_state: adapter_state,
        queues: queues,
        release_timers: release_timers
    }

    {:noreply, new_state}
  end

  defp finalize_after_request(state, _key, _method, _queue, in_flight, _now) when in_flight > 0,
    do: state

  defp finalize_after_request(state, key, method, queue, _in_flight, now) do
    if Queue.empty?(queue) do
      state
    else
      {blocked_until, adapter_state} = state.adapter.blocked_until(state.adapter_state, key, now)

      state
      |> Map.put(:adapter_state, adapter_state)
      |> maybe_process_waiters(key, method, queue, blocked_until, now)
    end
  end

  defp maybe_process_waiters(state, key, method, _queue, blocked_until, now)
       when future_blocked(blocked_until, now) do
    delay = Timer.clamp(blocked_until - now)
    release_timers = schedule_release_timer(state, key, method, delay)
    %{state | release_timers: release_timers}
  end

  defp maybe_process_waiters(state, key, _method, queue, _blocked_until, _now) do
    release_next_waiter(state, key, queue)
  end

  defp release_next_waiter(state, key, queue) do
    {{:value, {queued_from, queued_method}}, rest_queue} = Queue.pop(queue)
    queues = update_queue_map(state.queues, key, rest_queue)

    emit_decision(state.config, key, queued_method, :allow, Queue.size(rest_queue), 1)
    GenServer.reply(queued_from, :ok)

    in_flight_map = Map.put(state.in_flight, key, 1)
    %{state | queues: queues, in_flight: in_flight_map}
  end

  defp handle_release_event(state, %CallbackCtx{} = ctx)
       when future_blocked(ctx.blocked_until, ctx.now) do
    delay = Timer.clamp(ctx.blocked_until - ctx.now)
    release_timers = schedule_release_timer(state, ctx.key, ctx.method, delay)
    %{state | release_timers: release_timers}
  end

  defp handle_release_event(state, %CallbackCtx{in_flight: in_flight})
       when in_flight > 0,
       do: state

  defp handle_release_event(state, %CallbackCtx{} = ctx) do
    if Queue.empty?(ctx.queue) do
      state
    else
      {{:value, {queued_from, queued_method}}, rest_queue} = Queue.pop(ctx.queue)
      queues = update_queue_map(state.queues, ctx.key, rest_queue)

      emit_drain(state.config, ctx.key, 1, delay_ms: Timer.delay_ms(ctx.timer_info))
      emit_decision(state.config, ctx.key, queued_method, :allow, Queue.size(rest_queue), 1)
      GenServer.reply(queued_from, :ok)

      in_flight_map = Map.put(state.in_flight, ctx.key, 1)
      %{state | queues: queues, in_flight: in_flight_map}
    end
  end

  defp maybe_schedule_block_timer(
         state,
         %CallbackCtx{prev_queue_length: prev_queue_length}
       )
       when prev_queue_length > 0,
       do: state.release_timers

  defp maybe_schedule_block_timer(
         state,
         %CallbackCtx{blocked_until: blocked_until, now: now}
       )
       when not future_blocked(blocked_until, now),
       do: state.release_timers

  defp maybe_schedule_block_timer(state, %CallbackCtx{} = ctx) do
    delay = Timer.clamp(ctx.blocked_until - ctx.now)
    schedule_release_timer(state, ctx.key, ctx.method, delay)
  end

  defp schedule_release_timer(state, key, method, delay) do
    case Map.fetch(state.release_timers, key) do
      {:ok, _ref} ->
        state.release_timers

      :error ->
        ref = Process.send_after(self(), {:release_key, key}, delay)
        emit_blocked(state.config, key, method, delay)
        Map.put(state.release_timers, key, %{ref: ref, delay_ms: delay, method: method})
    end
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

  defp normalize_int(value) when is_integer(value) and value >= 0, do: value

  defp now_ms, do: System.monotonic_time(:millisecond)
end
