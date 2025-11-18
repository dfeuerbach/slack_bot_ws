defmodule SlackBot.Blocks do
  @moduledoc """
  Helpers for composing Slack Block Kit payloads with optional BlockBox integration.

  Configure `%SlackBot.Config{block_builder: {:blockbox, opts}}` to enable the BlockBox
  DSL (if the dependency is available). When BlockBox is not present—or when you leave
  the option as `:none`—the fallback helpers in this module produce idiomatic Block Kit
  maps.
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
  """
  @spec blockbox?(GenServer.server()) :: boolean()
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
      apply(BlockBox, :build, [fun])
    else
      Logger.warning(
        "[SlackBot] block_builder set to :blockbox but the dependency is not available. Falling back to map helpers."
      )

      fun.()
    end
  end

  defp blockbox_loaded? do
    Code.ensure_loaded?(BlockBox) and function_exported?(BlockBox, :build, 1)
  end

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
