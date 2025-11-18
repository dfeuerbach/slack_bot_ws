defmodule SlackBot.CommandGrammar do
  @moduledoc false

  def match(grammar, tokens) do
    with {:ok, rest, acc} <- reduce(grammar, tokens, %{}) do
      parsed =
        acc
        |> normalize_lists()
        |> maybe_put_extra(rest)

      {:ok, parsed}
    end
  end

  defp reduce([], tokens, acc), do: {:ok, tokens, acc}

  defp reduce([node | rest], tokens, acc) do
    case apply_node(node, tokens, acc) do
      {:ok, tokens, acc} -> reduce(rest, tokens, acc)
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_node({:literal, value, opts}, [token | rest], acc) do
    if normalize(token) == normalize(value) do
      {:ok, rest, assign_literal(acc, opts)}
    else
      {:error, {:expected, value}}
    end
  end

  defp apply_node({:literal, _value, _opts}, [], _acc), do: {:error, :missing_token}

  defp apply_node({:value, name, _opts}, [token | rest], acc) do
    {:ok, rest, Map.put(acc, name, token)}
  end

  defp apply_node({:value, _name, _opts}, [], _acc), do: {:error, :missing_token}

  defp apply_node({:optional, nodes}, tokens, acc) do
    case reduce(nodes, tokens, acc) do
      {:ok, tokens, acc} -> {:ok, tokens, acc}
      {:error, _} -> {:ok, tokens, acc}
    end
  end

  defp apply_node({:repeat, nodes}, tokens, acc) do
    stream_repeat(nodes, tokens, acc)
  end

  defp apply_node({:choice, branches}, tokens, acc) do
    Enum.reduce_while(branches, {:error, :no_choice}, fn branch, _ ->
      case reduce(branch, tokens, acc) do
        {:ok, tokens, acc} -> {:halt, {:ok, tokens, acc}}
        {:error, _} -> {:cont, {:error, :no_choice}}
      end
    end)
  end

  defp stream_repeat(nodes, tokens, acc) do
    case reduce(nodes, tokens, %{}) do
      {:ok, new_tokens, delta} ->
        merged = merge_repeat(acc, delta)
        stream_repeat(nodes, new_tokens, merged)

      {:error, _} ->
        {:ok, tokens, acc}
    end
  end

  defp merge_repeat(acc, delta) do
    Enum.reduce(delta, acc, fn {key, value}, acc ->
      Map.update(acc, key, [value], fn
        list when is_list(list) -> list ++ [value]
        existing -> [existing, value]
      end)
    end)
  end

  defp assign_literal(acc, opts) do
    case Keyword.get(opts, :as) do
      nil -> acc
      key -> Map.put(acc, key, Keyword.get(opts, :value, true))
    end
  end

  defp normalize(token) when is_binary(token), do: String.downcase(token)
  defp normalize(other), do: other

  defp normalize_lists(acc) do
    Enum.reduce(acc, %{}, fn
      {key, values}, acc when is_list(values) ->
        Map.put(acc, key, values)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp maybe_put_extra(map, []), do: map
  defp maybe_put_extra(map, rest), do: Map.put(map, :extra_args, rest)
end
