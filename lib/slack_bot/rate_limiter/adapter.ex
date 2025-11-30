defmodule SlackBot.RateLimiter.Adapter do
  @moduledoc """
  Behaviour for rate limiter backends.

  Implementations are responsible for tracking per-key blocking windows
  (for example, derived from Slack `429` responses and `Retry-After`
  hints). SlackBot's managed rate-limiter process owns queuing and
  in-flight coordination; adapters focus on persisting and querying
  block state.
  """

  alias SlackBot.Config

  @typedoc "Opaque adapter state."
  @type state :: term()

  @typedoc "Rate limit key (channel, workspace, or other scope)."
  @type key :: term()

  @doc """
  Initializes the adapter state for the given SlackBot instance.
  """
  @callback init(Config.t(), keyword()) :: {:ok, state()}

  @doc """
  Returns the current `blocked_until` timestamp for `key`, in milliseconds
  since `System.monotonic_time(:millisecond)`, or `nil` if the key is
  not currently blocked.
  """
  @callback blocked_until(state(), key(), non_neg_integer()) ::
              {non_neg_integer() | nil, state()}

  @doc """
  Updates adapter state after a request has completed.

  Implementations typically set or clear `blocked_until` based on the
  result (for example, when Slack returns `{:error, {:rate_limited, secs}}`).
  """
  @callback record_result(state(), key(), non_neg_integer(), term()) ::
              {:ok, state()}
end
