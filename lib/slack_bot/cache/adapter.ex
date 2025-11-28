defmodule SlackBot.Cache.Adapter do
  @moduledoc """
  Behaviour for cache backends.

  Implementations are responsible for supervising any required processes and for
  servicing read/write operations issued through `SlackBot.Cache`.
  """

  alias SlackBot.Config

  @callback child_specs(Config.t(), keyword()) :: [Supervisor.child_spec()]
  @callback channels(Config.t(), keyword()) :: [String.t()]
  @callback users(Config.t(), keyword()) :: map()
  @callback metadata(Config.t(), keyword()) :: map()
  @callback mutate(Config.t(), keyword(), SlackBot.Cache.cache_op()) :: :ok
  @callback user_entry(Config.t(), keyword(), String.t()) ::
              {:ok, %{data: map(), expires_at: integer()}} | :not_found
end
