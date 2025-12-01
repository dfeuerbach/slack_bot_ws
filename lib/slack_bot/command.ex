defmodule SlackBot.Command do
  @moduledoc """
  Tokenization helpers for slash commands.

  This module provides the lexer that powers SlackBot's slash command grammar DSL.
  It normalizes whitespace, respects quoted strings, and produces consistent tokens
  that the grammar matcher consumes.

  ## When to Use This Module

  **You typically don't need to call these functions directly.** The `slash/2` macro
  handles tokenization automatically. However, this module is useful when:

  - Testing your slash grammar patterns
  - Building custom command parsers outside the DSL
  - Debugging tokenization issues

  ## Tokenization Behavior

  The lexer handles:

  - **Whitespace normalization** - Multiple spaces collapse to single separators
  - **Quoted strings** - `"multiple words"` become a single token
  - **Command extraction** - Leading `/command` is separated from arguments

  ## Examples

      iex> SlackBot.Command.lex("/deploy api production")
      %{command: "deploy", tokens: ["api", "production"]}

      iex> SlackBot.Command.lex("/list \\"John Smith\\" --active")
      %{command: "list", tokens: ["John Smith", "--active"]}

      iex> SlackBot.Command.lex("    extra    spaces    ")
      %{command: nil, tokens: ["extra", "spaces"]}

  ## Grammar DSL

  The slash grammar DSL uses these tokens under the hood:

      slash "/deploy" do
        grammar do
          value :service        # Matches one token
          literal "canary"      # Matches the literal word "canary"
          repeat do
            literal "env"
            value :environments
          end
        end

        handle payload, _ctx do
          # payload["parsed"] contains the matched values
        end
      end

  ## See Also

  - [Slash Grammar Guide](https://hexdocs.pm/slack_bot_ws/slash_grammar.html)
  - The `slash/2` macro for defining command grammars
  - `BasicBot` - Example demonstrating complex grammar patterns
  """

  import NimbleParsec

  literal_word =
    ascii_string([?a..?z, ?A..?Z, ?0..?9, ?-, ?_, ?/, ?., ?:], min: 1)

  quoted =
    ignore(string("\""))
    |> repeat(lookahead_not(string("\"")) |> choice([literal_word, string(" ")]))
    |> ignore(string("\""))
    |> reduce({IO, :iodata_to_binary, []})

  token =
    choice([
      quoted,
      ascii_string([not: ?\s], min: 1)
    ])
    |> tag(:token)

  command =
    ignore(optional(ascii_string([?\s], min: 1)))
    |> ignore(string("/"))
    |> concat(literal_word)
    |> reduce({__MODULE__, :normalize_command, []})
    |> tag(:command)

  lexer =
    optional(command)
    |> optional(token)
    |> repeat(ignore(ascii_char([?\s])) |> concat(token))
    |> eos()
    |> reduce({__MODULE__, :build_tokens, []})

  defparsec(:do_lex, lexer)

  @doc false
  def normalize_command(["/", cmd]), do: cmd
  def normalize_command(cmd) when is_binary(cmd), do: cmd
  def normalize_command(cmd) when is_list(cmd), do: to_string(cmd)

  def build_tokens(items) do
    {command, tokens} =
      Enum.reduce(items, {nil, []}, fn
        {:command, cmd}, {_cmd, tokens} -> {to_binary(cmd), tokens}
        {:token, value}, {cmd, tokens} -> {cmd, [to_binary(value) | tokens]}
        nil, acc -> acc
      end)

    %{command: command && to_binary(command), tokens: Enum.reverse(tokens)}
  end

  defp to_binary(nil), do: nil
  defp to_binary(value) when is_binary(value), do: value
  defp to_binary(value) when is_list(value), do: IO.iodata_to_binary(value)

  @doc """
  Tokenizes slash command text, returning the optional command literal and a list of tokens.
  """
  @spec lex(String.t()) ::
          %{command: String.t() | nil, tokens: [String.t()]}
          | {:error, term()}
  def lex(text) when is_binary(text) do
    case do_lex(text) do
      {:ok, [result], _, _, _, _} ->
        result

      {:error, reason, rest, context, line, column} ->
        {:error, {reason, rest, context, line, column}}
    end
  end
end
