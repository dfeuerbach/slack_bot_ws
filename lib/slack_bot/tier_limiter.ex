defmodule SlackBot.TierLimiter do
  @moduledoc false

  use GenServer

  require Logger

  alias SlackBot.Config
  alias SlackBot.Telemetry
  alias SlackBot.TierRegistry

  @type option :: {:name, GenServer.name()} | {:config, Config.t()}

  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    name = server_name(config.instance_name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [[name: name, config: config]]},
      type: :worker
    }
  end

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    config = Keyword.fetch!(opts, :config)

    GenServer.start_link(__MODULE__, config, name: name)
  end

  @spec acquire(Config.t(), String.t(), map()) :: :ok
  def acquire(%Config{} = config, method, body) when is_binary(method) and is_map(body) do
    name = server_name(config.instance_name)

    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        GenServer.call(pid, {:acquire, method, body}, :infinity)
    end
  end

  @spec suspend(Config.t(), String.t(), map(), non_neg_integer()) :: :ok
  def suspend(%Config{} = config, method, body, delay_ms)
      when is_binary(method) and is_map(body) and is_integer(delay_ms) and delay_ms > 0 do
    name = server_name(config.instance_name)

    case Process.whereis(name) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:suspend, method, body, delay_ms})
    end
  end

  def suspend(_config, _method, _body, _delay_ms), do: :ok

  @impl true
  def init(config) do
    {:ok,
     %{
       config: config,
       buckets: %{}
     }}
  end

  @impl true
  def handle_call({:acquire, method, body}, from, state) do
    case TierRegistry.lookup(method) do
      :error ->
        {:reply, :ok, state}

      {:ok, spec} ->
        scope_key = scope_key(spec.scope, state.config, body)
        bucket_id = bucket_id(spec, method)
        bucket_key = {bucket_id, scope_key}
        now = now_ms()

        bucket =
          Map.get(state.buckets, bucket_key) ||
            new_bucket(spec, scope_key, bucket_id, now)

        bucket = refill(bucket, now)

        if bucket.tokens >= 1 and :queue.is_empty(bucket.queue) do
          bucket = spend_token(bucket)
          emit_decision(state.config, method, scope_key, :allow, 0, bucket.tokens)
          {:reply, :ok, put_bucket(state, bucket_key, bucket)}
        else
          bucket = enqueue_waiter(bucket, from, method)
          bucket = ensure_timer(bucket, bucket_key, now)

          emit_decision(
            state.config,
            method,
            scope_key,
            :queue,
            :queue.len(bucket.queue),
            bucket.tokens
          )

          {:noreply, put_bucket(state, bucket_key, bucket)}
        end
    end
  end

  @impl true
  def handle_info({:release_bucket, bucket_key}, state) do
    case Map.fetch(state.buckets, bucket_key) do
      :error ->
        {:noreply, state}

      {:ok, bucket} ->
        bucket = cancel_timer(bucket)
        now = now_ms()
        was_suspended? = suspended?(bucket)
        bucket = refill(bucket, now)
        bucket = maybe_emit_resume(bucket, state.config, was_suspended?)

        {bucket, replies} = allow_waiters(bucket, state.config)

        Enum.each(replies, fn from -> GenServer.reply(from, :ok) end)

        bucket = ensure_timer(bucket, bucket_key, now)

        {:noreply, put_bucket(state, bucket_key, bucket)}
    end
  end

  @impl true
  def handle_cast({:suspend, method, body, delay_ms}, state) do
    case TierRegistry.lookup(method) do
      :error ->
        {:noreply, state}

      {:ok, spec} ->
        scope_key = scope_key(spec.scope, state.config, body)
        bucket_id = bucket_id(spec, method)
        bucket_key = {bucket_id, scope_key}
        now = now_ms()

        bucket =
          Map.get(state.buckets, bucket_key) ||
            new_bucket(spec, scope_key, bucket_id, now)

        bucket =
          bucket
          |> cancel_timer()
          |> suspend_bucket(now, delay_ms, method)

        emit_suspend(state.config, method, scope_key, delay_ms)

        {:noreply, put_bucket(state, bucket_key, bucket)}
    end
  end

  defp new_bucket(spec, scope_key, bucket_id, now) do
    capacity = bucket_capacity(spec)
    refill_interval = max(spec.window_ms / max(spec.max_calls, 1), 1)
    tokens = initial_tokens(capacity, spec.initial_fill_ratio)

    %{
      spec: spec,
      scope_key: scope_key,
      bucket_id: bucket_id,
      capacity: capacity,
      refill_interval_ms: refill_interval,
      tokens: tokens,
      last_refill_ms: now,
      suspended_until: nil,
      queue: :queue.new(),
      timer_ref: nil,
      last_suspended_method: nil
    }
  end

  defp refill(%{suspended_until: suspended_until} = bucket, now)
       when is_integer(suspended_until) and suspended_until > now do
    bucket
  end

  defp refill(bucket, now) do
    elapsed = max(now - bucket.last_refill_ms, 0)

    if elapsed == 0 do
      bucket
    else
      tokens = min(bucket.capacity, bucket.tokens + elapsed / bucket.refill_interval_ms)
      %{bucket | tokens: tokens, last_refill_ms: now, suspended_until: nil}
    end
  end

  defp spend_token(bucket) do
    %{bucket | tokens: max(bucket.tokens - 1, 0.0)}
  end

  defp enqueue_waiter(bucket, from, method) do
    %{bucket | queue: :queue.in({from, method}, bucket.queue)}
  end

  defp ensure_timer(%{queue: queue} = bucket, bucket_key, now) do
    if :queue.is_empty(queue) do
      bucket
    else
      do_ensure_timer(bucket, bucket_key, now)
    end
  end

  defp do_ensure_timer(%{timer_ref: ref} = bucket, bucket_key, now) when is_reference(ref) do
    case next_available_ms(bucket, now) do
      :now ->
        send(self(), {:release_bucket, bucket_key})
        bucket

      _ ->
        bucket
    end
  end

  defp do_ensure_timer(bucket, bucket_key, now) do
    case next_available_ms(bucket, now) do
      :now ->
        send(self(), {:release_bucket, bucket_key})
        bucket

      wait_ms when is_integer(wait_ms) and wait_ms > 0 ->
        ref = Process.send_after(self(), {:release_bucket, bucket_key}, wait_ms)
        %{bucket | timer_ref: ref}
    end
  end

  defp next_available_ms(%{tokens: tokens}, _now) when tokens >= 1, do: :now

  defp next_available_ms(%{suspended_until: suspended_until}, now)
       when is_integer(suspended_until) and suspended_until > now do
    suspended_until - now
  end

  defp next_available_ms(bucket, _now) do
    shortage = max(1 - bucket.tokens, 0.0)
    wait_ms = shortage * bucket.refill_interval_ms
    wait_ms = Float.ceil(wait_ms) |> trunc
    max(wait_ms, 1)
  end

  defp allow_waiters(bucket, config) do
    do_allow_waiters(bucket, config, [])
  end

  defp do_allow_waiters(bucket, config, replies) do
    cond do
      :queue.is_empty(bucket.queue) ->
        {bucket, Enum.reverse(replies)}

      bucket.tokens >= 1 ->
        {{:value, {from, method}}, queue} = :queue.out(bucket.queue)
        bucket = %{bucket | queue: queue} |> spend_token()

        emit_decision(
          config,
          method,
          bucket.scope_key,
          :allow,
          :queue.len(bucket.queue),
          bucket.tokens
        )

        do_allow_waiters(bucket, config, [from | replies])

      true ->
        {bucket, Enum.reverse(replies)}
    end
  end

  defp emit_decision(config, method, scope_key, decision, queue_length, tokens) do
    Telemetry.execute(
      config,
      [:tier_limiter, :decision],
      %{count: 1, queue_length: queue_length, tokens: normalize_tokens(tokens)},
      %{method: method, scope_key: scope_key, decision: decision}
    )
  end

  defp normalize_tokens(value) when is_number(value) do
    value
    |> :erlang.float()
    |> Float.round(4)
  end

  defp normalize_tokens(_), do: 0.0

  defp put_bucket(state, key, bucket) do
    %{state | buckets: Map.put(state.buckets, key, bucket)}
  end

  defp bucket_id(%{group: group}, method), do: group || method

  defp scope_key(:workspace, config, _body), do: config.instance_name

  defp scope_key({:channel, field}, _config, body) do
    Map.get(body, field) || :workspace
  end

  defp scope_key(_, config, _body), do: config.instance_name

  defp server_name(instance_name) when is_atom(instance_name) do
    Module.concat(instance_name, TierLimiter)
  end

  defp bucket_capacity(%{capacity: capacity}) when is_integer(capacity) and capacity > 0,
    do: capacity

  defp bucket_capacity(%{max_calls: max_calls, burst_ratio: ratio}) do
    base = max(max_calls, 1)

    burst =
      case ratio do
        value when is_number(value) and value > 0 -> Float.ceil(base * value) |> trunc
        _ -> 0
      end

    base + burst
  end

  defp initial_tokens(capacity, ratio) do
    ratio = normalize_ratio(ratio)
    tokens = capacity * ratio
    tokens = min(tokens, capacity)
    max(tokens, 0.0)
  end

  defp normalize_ratio(ratio) when is_number(ratio) and ratio >= 0, do: ratio
  defp normalize_ratio(_), do: 0.0

  defp suspend_bucket(bucket, now, delay_ms, method) do
    resume_at = now + delay_ms

    %{
      bucket
      | tokens: 0.0,
        last_refill_ms: resume_at,
        suspended_until: resume_at,
        last_suspended_method: method
    }
  end

  defp cancel_timer(%{timer_ref: nil} = bucket), do: bucket

  defp cancel_timer(%{timer_ref: ref} = bucket) do
    Process.cancel_timer(ref)
    %{bucket | timer_ref: nil}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp emit_suspend(config, method, scope_key, delay_ms) do
    Telemetry.execute(
      config,
      [:tier_limiter, :suspend],
      %{delay_ms: delay_ms},
      %{method: method, scope_key: scope_key}
    )
  end

  defp emit_resume(config, bucket) do
    Telemetry.execute(
      config,
      [:tier_limiter, :resume],
      %{
        tokens: normalize_tokens(bucket.tokens),
        queue_length: :queue.len(bucket.queue)
      },
      %{
        bucket_id: bucket.bucket_id,
        scope_key: bucket.scope_key,
        method: bucket.last_suspended_method
      }
    )
  end

  defp suspended?(%{suspended_until: value}) when is_integer(value), do: true
  defp suspended?(_), do: false

  defp maybe_emit_resume(bucket, _config, false), do: bucket

  defp maybe_emit_resume(bucket, config, true) do
    if suspended?(bucket) do
      bucket
    else
      emit_resume(config, bucket)
      %{bucket | last_suspended_method: nil}
    end
  end
end
