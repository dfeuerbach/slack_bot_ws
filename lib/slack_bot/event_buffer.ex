defmodule SlackBot.EventBuffer do
  @moduledoc false

  alias SlackBot.EventBuffer.Adapters.ETS
  alias SlackBot.EventBuffer.Server
  alias SlackBot.Telemetry

  @type adapter_spec ::
          {:ets, keyword()}
          | {:adapter, module(), keyword()}

  @spec child_spec(SlackBot.Config.t()) :: Supervisor.child_spec()
  def child_spec(%SlackBot.Config{} = config) do
    {adapter, raw_opts} = adapter_from_config(config)
    name = server_name(config.instance_name)
    adapter_opts = Keyword.put_new(raw_opts, :instance_name, config.instance_name)

    %{
      id: name,
      start: {Server, :start_link, [[name: name, adapter: adapter, adapter_opts: adapter_opts]]},
      type: :worker
    }
  end

  @spec record(SlackBot.Config.t(), String.t() | nil, map()) :: :ok | :duplicate
  def record(%{instance_name: _instance} = config, nil, _payload) do
    Telemetry.execute(config, [:event_buffer, :record], %{}, %{key: nil, result: :ok})
    :ok
  end

  def record(%{instance_name: instance} = config, key, payload) do
    result =
      server_name(instance)
      |> GenServer.call({:record, key, payload})

    Telemetry.execute(config, [:event_buffer, :record], %{}, %{key: key, result: result})

    result
  end

  @spec delete(SlackBot.Config.t(), String.t() | nil) :: :ok
  def delete(%{instance_name: _instance} = config, nil) do
    Telemetry.execute(config, [:event_buffer, :delete], %{count: 0}, %{
      key: nil,
      key_present?: false
    })

    :ok
  end

  def delete(%{instance_name: instance} = config, key) do
    server_name(instance)
    |> GenServer.call({:delete, key})

    Telemetry.execute(config, [:event_buffer, :delete], %{count: 1}, %{
      key: key,
      key_present?: true
    })

    :ok
  end

  @spec seen?(SlackBot.Config.t(), String.t() | nil) :: boolean()
  def seen?(%{instance_name: _instance} = config, nil) do
    Telemetry.execute(config, [:event_buffer, :seen], %{count: 0}, %{key: nil, seen?: false})
    false
  end

  def seen?(%{instance_name: instance} = config, key) do
    value =
      server_name(instance)
      |> GenServer.call({:seen?, key})

    Telemetry.execute(config, [:event_buffer, :seen], %{count: 1}, %{key: key, seen?: value})
    value
  end

  @spec pending(SlackBot.Config.t()) :: list()
  def pending(%{instance_name: instance} = config) do
    value =
      server_name(instance)
      |> GenServer.call(:pending)

    Telemetry.execute(config, [:event_buffer, :pending], %{count: Enum.count(value)}, %{})

    value
  end

  defp server_name(instance_name) when is_atom(instance_name) do
    Module.concat(instance_name, :EventBuffer)
  end

  defp adapter_from_config(%{event_buffer: {:adapter, module, opts}}), do: {module, opts}
  defp adapter_from_config(%{event_buffer: {:ets, opts}}), do: {ETS, opts}
  defp adapter_from_config(_config), do: {ETS, []}
end
