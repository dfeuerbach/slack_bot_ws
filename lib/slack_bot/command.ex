defmodule SlackBot.Command do
  @moduledoc """
  NimbleParsec-based helpers for parsing slash commands and message text.
  """

  import NimbleParsec

  defmacro __using__(_opts) do
    quote do
      import SlackBot.Command
    end
  end

  word =
    ascii_string([?a..?z, ?A..?Z, ?0..?9, ?-, ?_, ?/, ?., ?:], min: 1)
    |> label("word")

  quoted =
    ignore(string("\""))
    |> repeat(lookahead_not(string("\"")) |> choice([word, string(" ")]))
    |> ignore(string("\""))
    |> reduce({IO, :iodata_to_binary, []})

  argument =
    choice([
      quoted,
      ascii_string([not: ?\s], min: 1)
    ])
    |> unwrap_and_tag(:arg)

  command =
    string("/")
    |> concat(word)
    |> reduce({__MODULE__, :normalize_command, []})

  def normalize_command(["/", cmd]), do: cmd

  token = argument

  slash_command =
    command
    |> repeat(ignore(ascii_char([?\s])) |> concat(token))
    |> eos()
    |> reduce({__MODULE__, :build_slash_command, []})

  defparsec(:do_parse_slash, slash_command)

  def build_slash_command(parts) do
    {cmd, tokens} = List.pop_at(parts, 0)

    {flags, args} =
      Enum.reduce(tokens, {%{}, []}, fn {:arg, value}, {flags, args} ->
        case classify_token(value) do
          {:flag, name, val} -> {Map.put(flags, name, val), args}
          :arg -> {flags, args ++ [value]}
        end
      end)

    %{
      command: cmd,
      flags: flags,
      args: args
    }
  end

  def parse_slash(text) when is_binary(text) do
    case do_parse_slash(text) do
      {:ok, [result], _, _, _, _} -> result
      {:error, reason, rest, context, line, column} -> {:error, reason, rest, context, line, column}
    end
  end

  defp classify_token("--" <> rest) do
    case String.split(rest, "=", parts: 2) do
      [name, value] -> {:flag, String.to_atom(name), value}
      _ -> :arg
    end
  end

  defp classify_token(_other), do: :arg
end
