defmodule SlackBot.RateLimiter.Queue do
  @moduledoc false

  @type t :: :queue.queue()

  @spec new() :: t()
  def new, do: :queue.new()

  @spec push(t(), term()) :: t()
  def push(queue, value), do: :queue.in(value, queue)

  @spec pop(t()) :: {{:value, term()}, t()}
  def pop(queue), do: :queue.out(queue)

  @spec empty?(t()) :: boolean()
  def empty?(queue), do: :queue.is_empty(queue)

  @spec size(t()) :: non_neg_integer()
  def size(queue), do: :queue.len(queue)
end
