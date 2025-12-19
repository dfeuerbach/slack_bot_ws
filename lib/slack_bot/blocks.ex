defmodule SlackBot.Blocks do
  @moduledoc """
  Helpers for composing Slack Block Kit payloads with optional [BlockBox](https://hex.pm/packages/blockbox) integration.

  Block Kit is Slack's framework for building rich, interactive messages with buttons,
  select menus, modals, and more. This module provides two ways to build Block Kit payloads:

  1. **With BlockBox** (recommended) - A clean DSL when you add BlockBox as a dependency
  2. **Manual helpers** - Lightweight functions that return Block Kit maps directly

  ## Configuration

  To enable BlockBox integration, add it to your `mix.exs`:

      def deps do
        [
          {:slack_bot_ws, "~> 0.1.0"},
          {:blockbox, "~> 1.2"}
        ]
      end

  Then configure your bot:

      config :my_app, MyApp.SlackBot,
        block_builder: {:blockbox, []}

  ## Usage with BlockBox

  When BlockBox is configured, `build/2` delegates to the BlockBox DSL:

      blocks = SlackBot.Blocks.build(MyApp.SlackBot, fn ->
        [
          SlackBot.Blocks.section("*Welcome!* Try these actions:"),
          SlackBot.Blocks.divider(),
          SlackBot.Blocks.section("Documentation",
            accessory: SlackBot.Blocks.button("Read docs", url: "https://hexdocs.pm/slack_bot_ws")
          )
        ]
      end)

      SlackBot.push(MyApp.SlackBot, {"chat.postMessage", %{
        channel: channel_id,
        text: "Welcome message",
        blocks: blocks
      }})

  ## Usage without BlockBox

  Without BlockBox, `build/2` simply executes your function, so you call the helpers directly:

      blocks =
        SlackBot.Blocks.build(MyApp.SlackBot, fn ->
          [
            SlackBot.Blocks.section("*Welcome!*"),
            SlackBot.Blocks.divider(),
            SlackBot.Blocks.context(["Built with SlackBot"])
          ]
        end)

  ## Available Helpers

  This module provides helpers for common Block Kit elements:

  - `section/2` - Text section with optional accessory (button, image, etc.)
  - `divider/0` - Visual separator
  - `context/1` - Small text or images for secondary information
  - `button/2` - Interactive button element
  - `markdown/1` - Markdown text object
  - `plain_text/1` - Plain text object

  ## See Also

  - [Block Kit documentation](https://api.slack.com/block-kit) - Official Slack guide
  - [BlockBox on Hex](https://hex.pm/packages/blockbox) - Elixir Block Kit DSL
  - Example app: `examples/basic_bot/`
  """

  require Logger

  @doc """
  Builds a block payload by running `fun`.

  - When BlockBox is enabled and loaded, delegates to `BlockBox.build/1`.
  - Otherwise, executes `fun` and returns the result (so you can call the helpers in
    this module to build the list of blocks).
  """
  @spec build(GenServer.server() | SlackBot.Config.t(), (-> term())) :: term()
  def build(%SlackBot.Config{} = config, fun) when is_function(fun, 0) do
    do_build(config, fun)
  end

  def build(server, fun) when is_function(fun, 0) do
    server
    |> SlackBot.config()
    |> do_build(fun)
  end

  @doc """
  Returns true when BlockBox is both configured and loaded.

  Accepts either a bot server (pid/name) or the bot's `%SlackBot.Config{}`.
  """
  @spec blockbox?(GenServer.server() | SlackBot.Config.t()) :: boolean()
  def blockbox?(%SlackBot.Config{} = config) do
    config.block_builder != :none and blockbox_loaded?()
  end

  def blockbox?(server) do
    server
    |> SlackBot.config()
    |> blockbox?()
  end

  @doc """
  Builds a `section` block with Markdown text.
  """
  @spec section(String.t(), keyword()) :: map()
  def section(text, opts \\ []) do
    base = %{
      "type" => "section",
      "text" => markdown(text)
    }

    maybe_accessory(base, opts)
  end

  @doc """
  Returns a Markdown text object.
  """
  @spec markdown(String.t()) :: map()
  def markdown(text) do
    %{"type" => "mrkdwn", "text" => text}
  end

  @doc """
  Returns a plain-text Slack object.
  """
  @spec plain_text(String.t()) :: map()
  def plain_text(text) do
    %{"type" => "plain_text", "text" => text, "emoji" => true}
  end

  @doc """
  Generates a divider block.
  """
  @spec divider() :: map()
  def divider do
    %{"type" => "divider"}
  end

  @doc """
  Builds a context block.
  """
  @spec context([map() | String.t()]) :: map()
  def context(elements) when is_list(elements) do
    %{
      "type" => "context",
      "elements" =>
        Enum.map(elements, fn
          %{} = element -> element
          binary when is_binary(binary) -> markdown(binary)
        end)
    }
  end

  @doc """
  Builds an actions block containing interactive elements (buttons, selects, etc.).
  """
  @spec actions([map()]) :: map()
  def actions(elements) do
    %{
      "type" => "actions",
      "elements" => elements
    }
  end

  @doc """
  Convenience helper for a button element.
  """
  @spec button(String.t(), keyword()) :: map()
  def button(text, opts \\ []) do
    %{
      "type" => "button",
      "text" => plain_text(text),
      "action_id" => Keyword.get(opts, :action_id, "action-#{System.unique_integer()}"),
      "value" => Keyword.get(opts, :value)
    }
    |> maybe_style(opts)
  end

  defp do_build(%SlackBot.Config{block_builder: {:blockbox, _opts}} = _config, fun) do
    if blockbox_loaded?() do
      run_blockbox(fun)
    else
      Logger.warning(
        "[SlackBot] block_builder set to :blockbox but the dependency is not available. Falling back to map helpers."
      )

      fun.()
    end
  end

  defp do_build(_config, fun), do: fun.()

  defp run_blockbox(fun) do
    if blockbox_loaded?() do
      blockbox_module()
      |> Function.capture(:build, 1)
      |> invoke_blockbox(fun)
    else
      Logger.warning(
        "[SlackBot] block_builder set to :blockbox but the dependency is not available. Falling back to map helpers."
      )

      fun.()
    end
  end

  defp blockbox_loaded? do
    module = blockbox_module()
    Code.ensure_loaded?(module) and function_exported?(module, :build, 1)
  end

  defp blockbox_module, do: Module.concat([Elixir, :BlockBox])

  defp invoke_blockbox(fun, arg), do: fun.(arg)

  defp maybe_accessory(block, opts) do
    case Keyword.get(opts, :accessory) do
      nil -> block
      accessory -> Map.put(block, "accessory", accessory)
    end
  end

  defp maybe_style(button, opts) do
    case Keyword.get(opts, :style) do
      nil -> button
      style -> Map.put(button, "style", Atom.to_string(style))
    end
  end
end
