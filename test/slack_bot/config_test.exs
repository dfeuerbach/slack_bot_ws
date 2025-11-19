defmodule SlackBot.ConfigTest do
  use ExUnit.Case, async: true

  alias SlackBot.Config

  @handler SlackBot.TestHandler
  @valid_opts [app_token: "xapp-123", bot_token: "xoxb-123", module: @handler]

  setup do
    original = Application.get_env(:slack_bot_ws, SlackBot)
    Application.delete_env(:slack_bot_ws, SlackBot)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:slack_bot_ws, SlackBot),
        else: Application.put_env(:slack_bot_ws, SlackBot, original)
    end)

    :ok
  end

  describe "build/1" do
    test "returns struct when required options provided" do
      assert {:ok, %Config{} = config} = Config.build(@valid_opts)
      assert config.app_token == "xapp-123"
      assert config.module == @handler
    end

    test "merges application env defaults" do
      Application.put_env(:slack_bot_ws, SlackBot,
        app_token: "env-app",
        bot_token: "env-bot",
        module: @handler
      )

      on_exit(fn -> Application.delete_env(:slack_bot_ws, SlackBot) end)

      assert {:ok, %Config{} = config} = Config.build()
      assert config.app_token == "env-app"
      assert config.bot_token == "env-bot"
    end

    test "validates presence of tokens" do
      assert {:error, {:missing_option, :app_token}} =
               Config.build(Keyword.delete(@valid_opts, :app_token))

      assert {:error, {:missing_option, :bot_token}} =
               Config.build(Keyword.delete(@valid_opts, :bot_token))

      assert {:error, {:missing_option, :module}} =
               Config.build(Keyword.delete(@valid_opts, :module))
    end

    test "validates ack mode tuple" do
      assert {:error, {:invalid_ack_mode, :bad}} =
               Config.build(Keyword.put(@valid_opts, :ack_mode, :bad))

      fun = fn _, _ -> :ok end

      assert {:ok, %Config{ack_mode: {:custom, ^fun}}} =
               Config.build(Keyword.put(@valid_opts, :ack_mode, {:custom, fun}))
    end

    test "accepts custom ack client module" do
      assert {:ok, %Config{ack_client: TestAckClient}} =
               Config.build(Keyword.put(@valid_opts, :ack_client, TestAckClient))

      assert {:error, {:invalid_module_option, :ack_client, 123}} =
               Config.build(Keyword.put(@valid_opts, :ack_client, 123))
    end

    test "validates diagnostics options" do
      assert {:ok, %Config{diagnostics: %{enabled: true, buffer_size: 50}}} =
               Config.build(
                 Keyword.put(@valid_opts, :diagnostics, enabled: true, buffer_size: 50)
               )

      assert {:error, {:invalid_diagnostics_buffer, 0}} =
               Config.build(Keyword.put(@valid_opts, :diagnostics, buffer_size: 0))
    end

    test "validates backoff jitter ratio" do
      assert {:ok, %Config{backoff: %{jitter_ratio: 0.5}}} =
               Config.build(Keyword.put(@valid_opts, :backoff, %{jitter_ratio: 0.5}))

      assert {:error, {:invalid_backoff_jitter, -0.1}} =
               Config.build(Keyword.put(@valid_opts, :backoff, %{jitter_ratio: -0.1}))

      assert {:error, {:invalid_backoff_jitter, 2}} =
               Config.build(Keyword.put(@valid_opts, :backoff, %{jitter_ratio: 2}))
    end
  end

  describe "build!/1" do
    test "returns struct on success" do
      assert %Config{} = Config.build!(@valid_opts)
    end

    test "raises when invalid" do
      assert_raise ArgumentError, fn ->
        Config.build!(Keyword.delete(@valid_opts, :app_token))
      end
    end
  end
end

defmodule TestAckClient do
  @behaviour SlackBot.SlashAck.HttpClient

  @impl true
  def post(_url, _body, _config), do: :ok
end
