defmodule SlackBot.Config do
  @moduledoc """
  Runtime configuration builder for `SlackBot`.

  The module merges application environment defaults with runtime overrides,
  validates required options, and returns a structured `%SlackBot.Config{}` that
  other processes can consume without re-validating input.
  """

  @app :slack_bot_ws
  @positive_defaults %{heartbeat_ms: 15_000, ping_timeout_ms: 5_000}

  alias SlackBot.API
  alias SlackBot.Socket
  alias SlackBot.SlashAck.HTTP, as: AckHTTP

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
    block_builder: :none,
    backoff: %{min_ms: 1_000, max_ms: 30_000, max_attempts: :infinity, jitter_ratio: 0.2},
    heartbeat_ms: 15_000,
    ping_timeout_ms: 5_000,
    ack_mode: :silent,
    ack_client: AckHTTP,
    api_pool_opts: [],
    diagnostics: %{enabled: false, buffer_size: 200},
    log_level: :info
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
          block_builder: :none | {:blockbox, keyword()},
          backoff: %{
            min_ms: pos_integer(),
            max_ms: pos_integer(),
            max_attempts: pos_integer() | :infinity,
            jitter_ratio: number()
          },
          heartbeat_ms: pos_integer(),
          ping_timeout_ms: pos_integer(),
          ack_mode: :silent | :ephemeral | {:custom, (map(), t() -> any())},
          ack_client: module(),
          api_pool_opts: keyword(),
          diagnostics: %{
            enabled: boolean(),
            buffer_size: pos_integer()
          },
          log_level: Logger.level()
        }

  @doc """
  Builds a `%SlackBot.Config{}` by merging application environment defaults with the provided `opts`.

  ## Examples

      iex> defmodule MyBot do
      ...>   def handle_event(_type, _event, _ctx), do: :ok
      ...> end
      iex> Application.put_env(:slack_bot_ws, SlackBot, app_token: "xapp-1", bot_token: "xoxb-1", module: MyBot)
      iex> SlackBot.Config.build()
      {:ok, %SlackBot.Config{app_token: "xapp-1", bot_token: "xoxb-1", module: MyBot}}

      iex> SlackBot.Config.build(app_token: "xapp", bot_token: "", module: MyBot)
      {:error, {:invalid_bot_token, ""}}
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
         {:ok, block_builder} <- fetch_block_builder(opts),
         {:ok, backoff} <- fetch_backoff(opts),
         {:ok, heartbeat_ms} <- fetch_positive(opts, :heartbeat_ms),
         {:ok, ping_timeout_ms} <- fetch_positive(opts, :ping_timeout_ms),
         {:ok, ack_mode} <- fetch_ack_mode(opts),
         {:ok, ack_client} <- fetch_module_option(opts, :ack_client, AckHTTP),
         {:ok, api_pool_opts} <- fetch_keyword(opts, :api_pool_opts, []),
         {:ok, diagnostics} <- fetch_diagnostics(opts),
         {:ok, log_level} <- fetch_log_level(opts) do
      {:ok,
       struct!(__MODULE__, %{
         app_token: app_token,
         bot_token: bot_token,
         module: module,
         telemetry_prefix: telemetry_prefix,
         cache: cache,
         event_buffer: event_buffer,
         block_builder: block_builder,
         backoff: backoff,
         heartbeat_ms: heartbeat_ms,
         ping_timeout_ms: ping_timeout_ms,
         ack_mode: ack_mode,
         ack_client: ack_client,
         api_pool_opts: api_pool_opts,
         diagnostics: diagnostics,
         log_level: log_level,
         transport: transport,
         transport_opts: transport_opts,
         http_client: http_client,
         assigns: assigns,
         instance_name: Keyword.get(opts, :instance_name)
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

  defp fetch_positive(opts, key) do
    value = Keyword.get(opts, key, Map.fetch!(@positive_defaults, key))

    if positive?(value) do
      {:ok, value}
    else
      {:error, {:invalid_positive_option, key, value}}
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

  defp valid_jitter?(value) when is_number(value), do: value >= 0 and value <= 1
  defp valid_jitter?(_), do: false

  defp positive?(value) when is_integer(value) and value > 0, do: true
  defp positive?(_), do: false
end
