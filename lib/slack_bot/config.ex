defmodule SlackBot.Config do
  @moduledoc """
  Runtime configuration builder for `SlackBot`.

  The module merges application environment defaults with runtime overrides,
  validates required options, and returns a structured `%SlackBot.Config{}` that
  other processes can consume without re-validating input.
  """

  @app :slack_bot_ws
  alias SlackBot.API
  alias SlackBot.Socket
  alias SlackBot.SlashAck.HTTP, as: AckHTTP
  alias SlackBot.RateLimiter.Adapters.ETS, as: RateLimiterETS

  @enforce_keys [:app_token, :bot_token, :module]
  defstruct [
    :app_token,
    :bot_token,
    :module,
    instance_name: nil,
    transport: Socket,
    transport_opts: [],
    http_client: API,
    assigns: %{},
    telemetry_prefix: [:slackbot],
    cache: {:ets, []},
    event_buffer: {:ets, []},
    rate_limiter: {:adapter, RateLimiterETS, []},
    block_builder: :none,
    backoff: %{
      min_ms: 1_000,
      max_ms: 30_000,
      max_attempts: :infinity,
      jitter_ratio: 0.2
    },
    ack_mode: :silent,
    ack_client: AckHTTP,
    api_pool_opts: [],
    diagnostics: %{enabled: false, buffer_size: 200},
    log_level: :info,
    health_check: %{enabled: true, interval_ms: 30_000},
    user_cache: %{
      ttl_ms: 3_600_000,
      cleanup_interval_ms: 300_000
    },
    cache_sync: %{
      enabled: true,
      interval_ms: 3_600_000,
      kinds: [:channels],
      page_limit: :infinity,
      include_presence: false,
      users_conversations_opts: %{}
    },
    telemetry_stats: %{
      enabled: false,
      flush_interval_ms: 15_000,
      ttl_ms: 300_000
    }
  ]

  @type t :: %__MODULE__{
          app_token: String.t(),
          bot_token: String.t(),
          module: module(),
          instance_name: atom() | nil,
          transport: module(),
          transport_opts: keyword(),
          http_client: module(),
          assigns: map(),
          telemetry_prefix: [atom()],
          cache: {:ets | :adapter, any()},
          event_buffer: {:ets | :adapter, any()},
          rate_limiter: :none | {:adapter, module(), keyword()},
          block_builder: :none | {:blockbox, keyword()},
          backoff: %{
            min_ms: pos_integer(),
            max_ms: pos_integer(),
            max_attempts: pos_integer() | :infinity,
            jitter_ratio: number()
          },
          ack_mode: :silent | :ephemeral | {:custom, (map(), t() -> any())},
          ack_client: module(),
          api_pool_opts: keyword(),
          diagnostics: %{
            enabled: boolean(),
            buffer_size: pos_integer()
          },
          log_level: Logger.level(),
          health_check: %{
            enabled: boolean(),
            interval_ms: pos_integer()
          },
          user_cache: %{
            ttl_ms: pos_integer(),
            cleanup_interval_ms: pos_integer()
          },
          cache_sync: %{
            enabled: boolean(),
            interval_ms: pos_integer(),
            kinds: [atom()],
            page_limit: pos_integer() | :infinity,
            include_presence: boolean(),
            users_conversations_opts: map()
          },
          telemetry_stats: %{
            enabled: boolean(),
            flush_interval_ms: pos_integer(),
            ttl_ms: pos_integer()
          }
        }

  @doc """
  Builds a `%SlackBot.Config{}` by merging application environment defaults with the provided `opts`.

  Returns `{:ok, config}` on success, or `{:error, reason}` if validation fails.

  ## Examples

      # With explicit options
      SlackBot.Config.build(
        app_token: "xapp-...",
        bot_token: "xoxb-...",
        module: MyApp.SlackBot
      )
      #=> {:ok, %SlackBot.Config{...}}

      # Missing or empty tokens return errors
      SlackBot.Config.build(app_token: "xapp-...", bot_token: "", module: MyBot)
      #=> {:error, {:invalid_bot_token, ""}}
  """
  @spec build(keyword()) :: {:ok, t()} | {:error, term()}
  def build(opts \\ []) when is_list(opts) do
    opts
    |> merge_with_env()
    |> do_build()
  end

  @doc """
  Same as `build/1`, but raises on validation errors.
  """
  @spec build!(keyword()) :: t()
  def build!(opts \\ []) do
    case build(opts) do
      {:ok, config} ->
        config

      {:error, reason} ->
        raise ArgumentError, "invalid slack bot configuration: #{inspect(reason)}"
    end
  end

  defp merge_with_env(opts) do
    env_opts =
      Application.get_env(@app, SlackBot, [])
      |> Keyword.merge(Application.get_env(@app, __MODULE__, []))

    Keyword.merge(env_opts, opts)
  end

  defp do_build(opts) do
    with {:ok, app_token} <- fetch_binary(opts, :app_token, :invalid_app_token),
         {:ok, bot_token} <- fetch_binary(opts, :bot_token, :invalid_bot_token),
         {:ok, module} <- fetch_module(opts),
         {:ok, telemetry_prefix} <- fetch_prefix(opts),
         {:ok, transport} <- fetch_module_option(opts, :transport, Socket),
         {:ok, transport_opts} <- fetch_keyword(opts, :transport_opts, []),
         {:ok, http_client} <- fetch_module_option(opts, :http_client, API),
         {:ok, assigns} <- fetch_assigns(opts),
         {:ok, cache} <- fetch_cache(opts),
         {:ok, event_buffer} <- fetch_event_buffer(opts),
         {:ok, rate_limiter} <- fetch_rate_limiter(opts),
         {:ok, block_builder} <- fetch_block_builder(opts),
         {:ok, backoff} <- fetch_backoff(opts),
         {:ok, ack_mode} <- fetch_ack_mode(opts),
         {:ok, ack_client} <- fetch_module_option(opts, :ack_client, AckHTTP),
         {:ok, api_pool_opts} <- fetch_keyword(opts, :api_pool_opts, []),
         {:ok, diagnostics} <- fetch_diagnostics(opts),
         {:ok, log_level} <- fetch_log_level(opts),
         {:ok, health_check} <- fetch_health_check(opts),
         {:ok, user_cache} <- fetch_user_cache(opts),
         {:ok, cache_sync} <- fetch_cache_sync(opts),
         {:ok, telemetry_stats} <- fetch_telemetry_stats(opts) do
      {:ok,
       struct!(__MODULE__, %{
         app_token: app_token,
         bot_token: bot_token,
         module: module,
         telemetry_prefix: telemetry_prefix,
         cache: cache,
         event_buffer: event_buffer,
         rate_limiter: rate_limiter,
         block_builder: block_builder,
         backoff: backoff,
         ack_mode: ack_mode,
         ack_client: ack_client,
         api_pool_opts: api_pool_opts,
         diagnostics: diagnostics,
         log_level: log_level,
         transport: transport,
         transport_opts: transport_opts,
         http_client: http_client,
         assigns: assigns,
         instance_name: Keyword.get(opts, :instance_name),
         health_check: health_check,
         user_cache: user_cache,
         cache_sync: cache_sync,
         telemetry_stats: telemetry_stats
       })}
    end
  end

  defp fetch_binary(opts, key, error_tag) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} -> {:error, {error_tag, value}}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp fetch_module(opts) do
    case Keyword.fetch(opts, :module) do
      {:ok, value} when is_atom(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_module, value}}
      :error -> {:error, {:missing_option, :module}}
    end
  end

  defp fetch_module_option(opts, key, default) do
    module = Keyword.get(opts, key, default)

    if is_atom(module) do
      {:ok, module}
    else
      {:error, {:invalid_module_option, key, module}}
    end
  end

  defp fetch_keyword(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if Keyword.keyword?(value) do
      {:ok, value}
    else
      {:error, {:invalid_keyword_option, key, value}}
    end
  end

  defp fetch_assigns(opts) do
    case Keyword.get(opts, :assigns, %{}) do
      %{} = assigns -> {:ok, assigns}
      other -> {:error, {:invalid_assigns, other}}
    end
  end

  defp fetch_prefix(opts) do
    prefix = Keyword.get(opts, :telemetry_prefix, [:slackbot])

    if Enum.all?(prefix, &is_atom/1) do
      {:ok, prefix}
    else
      {:error, {:invalid_telemetry_prefix, prefix}}
    end
  end

  defp fetch_cache(opts) do
    case Keyword.get(opts, :cache, {:ets, []}) do
      {:ets, adapter_opts} when is_list(adapter_opts) ->
        {:ok, {:ets, adapter_opts}}

      {:adapter, module} when is_atom(module) ->
        {:ok, {:adapter, module, []}}

      {:adapter, module, adapter_opts} when is_atom(module) and is_list(adapter_opts) ->
        {:ok, {:adapter, module, adapter_opts}}

      other ->
        {:error, {:invalid_cache_option, other}}
    end
  end

  defp fetch_event_buffer(opts) do
    case Keyword.get(opts, :event_buffer, {:ets, []}) do
      {:ets, adapter_opts} when is_list(adapter_opts) ->
        {:ok, {:ets, adapter_opts}}

      {:adapter, module} when is_atom(module) ->
        {:ok, {:adapter, module, []}}

      {:adapter, module, adapter_opts} when is_atom(module) and is_list(adapter_opts) ->
        {:ok, {:adapter, module, adapter_opts}}

      other ->
        {:error, {:invalid_event_buffer_option, other}}
    end
  end

  defp fetch_rate_limiter(opts) do
    default = {:adapter, RateLimiterETS, []}

    case Keyword.get(opts, :rate_limiter, default) do
      :none ->
        {:ok, :none}

      {:adapter, module} when is_atom(module) ->
        {:ok, {:adapter, module, []}}

      {:adapter, module, adapter_opts} when is_atom(module) and is_list(adapter_opts) ->
        {:ok, {:adapter, module, adapter_opts}}

      other ->
        {:error, {:invalid_rate_limiter_option, other}}
    end
  end

  defp fetch_block_builder(opts) do
    case Keyword.get(opts, :block_builder, :none) do
      :none -> {:ok, :none}
      {:blockbox, kw} when is_list(kw) -> {:ok, {:blockbox, kw}}
      other -> {:error, {:invalid_block_builder, other}}
    end
  end

  defp fetch_backoff(opts) do
    backoff = Keyword.get(opts, :backoff, %{})
    defaults = %{min_ms: 1_000, max_ms: 30_000, max_attempts: :infinity, jitter_ratio: 0.2}

    merged = Map.merge(defaults, Map.new(backoff))

    cond do
      not positive?(merged.min_ms) ->
        {:error, {:invalid_backoff_min, merged.min_ms}}

      not positive?(merged.max_ms) ->
        {:error, {:invalid_backoff_max, merged.max_ms}}

      merged.max_attempts != :infinity and not positive?(merged.max_attempts) ->
        {:error, {:invalid_backoff_attempts, merged.max_attempts}}

      not valid_jitter?(merged.jitter_ratio) ->
        {:error, {:invalid_backoff_jitter, merged.jitter_ratio}}

      true ->
        {:ok, merged}
    end
  end

  defp fetch_ack_mode(opts) do
    case Keyword.get(opts, :ack_mode, :silent) do
      :silent -> {:ok, :silent}
      :ephemeral -> {:ok, :ephemeral}
      {:custom, fun} when is_function(fun, 2) -> {:ok, {:custom, fun}}
      other -> {:error, {:invalid_ack_mode, other}}
    end
  end

  defp fetch_log_level(opts) do
    level = Keyword.get(opts, :log_level, :info)

    if level in [:debug, :info, :warning, :error] do
      {:ok, level}
    else
      {:error, {:invalid_log_level, level}}
    end
  end

  defp fetch_diagnostics(opts) do
    raw = Keyword.get(opts, :diagnostics, [])
    defaults = %{enabled: false, buffer_size: 200}

    map =
      cond do
        is_list(raw) -> Map.merge(defaults, Map.new(raw))
        is_map(raw) -> Map.merge(defaults, raw)
        is_boolean(raw) -> Map.put(defaults, :enabled, raw)
        true -> :invalid
      end

    with %{enabled: enabled, buffer_size: buffer_size} = value when map != :invalid <- map,
         true <- is_boolean(enabled) || {:error, {:invalid_diagnostics_enabled, enabled}},
         true <- positive?(buffer_size) || {:error, {:invalid_diagnostics_buffer, buffer_size}} do
      {:ok, value}
    else
      :invalid -> {:error, {:invalid_diagnostics_option, raw}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_health_check(opts) do
    raw = Keyword.get(opts, :health_check, [])
    defaults = %{enabled: true, interval_ms: 30_000}

    map =
      cond do
        is_list(raw) -> Map.merge(defaults, Map.new(raw))
        is_map(raw) -> Map.merge(defaults, raw)
        is_boolean(raw) -> Map.put(defaults, :enabled, raw)
        is_integer(raw) and raw > 0 -> %{enabled: true, interval_ms: raw}
        true -> :invalid
      end

    with %{enabled: enabled, interval_ms: interval_ms} = value when map != :invalid <- map,
         true <- is_boolean(enabled) || {:error, {:invalid_health_check_enabled, enabled}},
         true <- positive?(interval_ms) || {:error, {:invalid_health_check_interval, interval_ms}} do
      {:ok, value}
    else
      :invalid -> {:error, {:invalid_health_check_option, raw}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_user_cache(opts) do
    raw = Keyword.get(opts, :user_cache, [])
    defaults = %{ttl_ms: 3_600_000, cleanup_interval_ms: 300_000}

    map =
      cond do
        is_list(raw) -> Map.merge(defaults, Map.new(raw))
        is_map(raw) -> Map.merge(defaults, raw)
        true -> defaults
      end

    with %{ttl_ms: ttl_ms, cleanup_interval_ms: cleanup} = value <- map,
         true <- positive?(ttl_ms) || {:error, {:invalid_user_cache_ttl, ttl_ms}},
         true <- positive?(cleanup) || {:error, {:invalid_user_cache_cleanup, cleanup}} do
      {:ok, value}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_telemetry_stats(opts) do
    raw = Keyword.get(opts, :telemetry_stats, [])
    defaults = %{enabled: false, flush_interval_ms: 15_000, ttl_ms: 300_000}

    map =
      cond do
        is_list(raw) -> Map.merge(defaults, Map.new(raw))
        is_map(raw) -> Map.merge(defaults, raw)
        is_boolean(raw) -> Map.put(defaults, :enabled, raw)
        true -> :invalid
      end

    with %{enabled: enabled, flush_interval_ms: flush, ttl_ms: ttl} = value when map != :invalid <-
           map,
         true <- is_boolean(enabled) || {:error, {:invalid_telemetry_stats_enabled, enabled}},
         true <- positive?(flush) || {:error, {:invalid_telemetry_stats_flush, flush}},
         true <- positive?(ttl) || {:error, {:invalid_telemetry_stats_ttl, ttl}} do
      {:ok, value}
    else
      :invalid -> {:error, {:invalid_telemetry_stats_option, raw}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_cache_sync(opts) do
    raw = Keyword.get(opts, :cache_sync, [])

    defaults = %{
      enabled: true,
      interval_ms: 3_600_000,
      kinds: [:channels],
      page_limit: :infinity,
      include_presence: false,
      users_conversations_opts: %{}
    }

    map =
      cond do
        is_list(raw) -> Map.merge(defaults, Map.new(raw))
        is_map(raw) -> Map.merge(defaults, raw)
        is_boolean(raw) -> Map.put(defaults, :enabled, raw)
        is_integer(raw) and raw > 0 -> %{defaults | enabled: true, interval_ms: raw}
        true -> :invalid
      end

    with %{
           enabled: enabled,
           interval_ms: interval_ms,
           kinds: kinds,
           page_limit: page_limit,
           include_presence: include_presence,
           users_conversations_opts: users_conversations_opts
         } = value
         when map != :invalid <- map,
         true <- is_boolean(enabled) || {:error, {:invalid_cache_sync_enabled, enabled}},
         true <- positive?(interval_ms) || {:error, {:invalid_cache_sync_interval, interval_ms}},
         true <- valid_kinds?(kinds) || {:error, {:invalid_cache_sync_kinds, kinds}},
         true <-
           (page_limit == :infinity or (is_integer(page_limit) and page_limit > 0)) ||
             {:error, {:invalid_cache_sync_page_limit, page_limit}},
         true <-
           is_boolean(include_presence) ||
             {:error, {:invalid_cache_sync_presence, include_presence}},
         {:ok, normalized_opts} <- normalize_users_conversations_opts(users_conversations_opts) do
      {:ok, %{value | users_conversations_opts: normalized_opts}}
    else
      :invalid -> {:error, {:invalid_cache_sync_option, raw}}
      {:error, _} = error -> error
    end
  end

  defp valid_jitter?(value) when is_number(value), do: value >= 0 and value <= 1
  defp valid_jitter?(_), do: false

  defp valid_kinds?(kinds) when is_list(kinds) and kinds != [] do
    Enum.all?(kinds, &(&1 in [:users, :channels]))
  end

  defp valid_kinds?(_), do: false

  defp normalize_users_conversations_opts(value) when is_map(value), do: {:ok, value}

  defp normalize_users_conversations_opts(value) when is_list(value) do
    {:ok, Map.new(value)}
  rescue
    ArgumentError ->
      {:error, {:invalid_cache_sync_channel_opts, value}}
  end

  defp normalize_users_conversations_opts(_value),
    do: {:error, {:invalid_cache_sync_channel_opts, :invalid}}

  defp positive?(value) when is_integer(value) and value > 0, do: true
  defp positive?(_), do: false
end
