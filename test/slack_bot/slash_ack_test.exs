defmodule SlackBot.SlashAckTest do
  use ExUnit.Case, async: true

  alias SlackBot.SlashAck

  defmodule MockClient do
    @behaviour SlackBot.SlashAck.HttpClient

    @impl true
    def post(url, body) do
      if pid = Process.get(:ack_test_pid) do
        send(pid, {:ack_post, url, body})
      end

      :ok
    end
  end

  defp config(overrides \\ []) do
    base =
      Map.from_struct(%SlackBot.Config{
        app_token: "xapp",
        bot_token: "xoxb",
        module: __MODULE__,
        ack_client: MockClient,
        assigns: %{},
        instance_name: :slash_ack_test
      })

    override_map = Enum.into(overrides, %{})
    struct!(SlackBot.Config, Map.merge(base, override_map))
  end

  test "silent mode is a no-op" do
    assert :ok == SlashAck.maybe_ack(:silent, %{}, config())
  end

  test "ephemeral mode posts via the ack client when response_url present" do
    Process.put(:ack_test_pid, self())

    cfg = config(assigns: %{slash_ack_text: "Hang tight"})

    SlashAck.maybe_ack(:ephemeral, %{"response_url" => "https://slack.test/resp"}, cfg)

    assert_receive {:ack_post, "https://slack.test/resp",
                    %{
                      response_type: "ephemeral",
                      text: "Hang tight",
                      replace_original: false
                    }}
  after
    Process.delete(:ack_test_pid)
  end

  test "ephemeral mode does nothing when response_url missing" do
    Process.put(:ack_test_pid, self())

    SlashAck.maybe_ack(:ephemeral, %{}, config())
    refute_receive {:ack_post, _, _}
  after
    Process.delete(:ack_test_pid)
  end

  test "custom mode delegates to provided function" do
    parent = self()
    cfg = config()

    fun = fn payload, _config ->
      send(parent, {:custom_ack, payload})
      :ok
    end

    SlashAck.maybe_ack({:custom, fun}, %{"text" => "deploy"}, cfg)

    assert_receive {:custom_ack, %{"text" => "deploy"}}
  end
end
