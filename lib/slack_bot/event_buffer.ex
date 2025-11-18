defmodule SlackBot.EventBuffer do
  @moduledoc false

  alias SlackBot.EventBuffer.Server
  alias SlackBot.EventBuffer.Adapters.ETS

  @type adapter_spec ::
          {:ets, keyword()}
          | {:adapter, module(), keyword()}

  @spec child_spec(SlackBot.Config.t()) :: Supervisor.child_spec()
  def child_spec(config) do
    {adapter, opts} = adapter_from_config(config)
    name = server_name(config.instance_name)

    %{
      id: name,
      start: {Server, :start_link, [[name: name, adapter: adapter, adapter_opts: opts]]},
      type: :worker
    }
  end

  @spec record(SlackBot.Config.t(), String.t() | nil, map()) :: :ok
  def record(%{instance_name: _instance}, nil, _payload), do: :ok

  def record(%{instance_name: instance}, key, payload) do
    server_name(instance)
    |> GenServer.cast({:record, key, payload})
  end

  @spec delete(SlackBot.Config.t(), String.t() | nil) :: :ok
  def delete(%{instance_name: _instance}, nil), do: :ok

  def delete(%{instance_name: instance}, key) do
    server_name(instance)
    |> GenServer.cast({:delete, key})
  end

  @spec seen?(SlackBot.Config.t(), String.t() | nil) :: boolean()
  def seen?(%{instance_name: _instance}, nil), do: false

  def seen?(%{instance_name: instance}, key) do
    server_name(instance)
    |> GenServer.call({:seen?, key})
  end

  @spec pending(SlackBot.Config.t()) :: list()
  def pending(%{instance_name: instance}) do
    server_name(instance)
    |> GenServer.call(:pending)
  end

  defp server_name(instance_name) when is_atom(instance_name) do
    Module.concat(instance_name, :EventBuffer)
  end

  defp adapter_from_config(%{event_buffer: {:adapter, module, opts}}), do: {module, opts}
  defp adapter_from_config(%{event_buffer: {:ets, opts}}), do: {ETS, opts}
  defp adapter_from_config(_config), do: {ETS, []}
end
