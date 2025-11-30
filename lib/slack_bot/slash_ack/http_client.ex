defmodule SlackBot.SlashAck.HttpClient do
  @moduledoc false

  @callback post(String.t(), map(), SlackBot.Config.t()) :: :ok | {:error, term()}
end
