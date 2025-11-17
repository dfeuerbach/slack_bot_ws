defmodule SlackBotTest do
  use ExUnit.Case
  doctest SlackBot

  test "greets the world" do
    assert SlackBot.hello() == :world
  end
end
