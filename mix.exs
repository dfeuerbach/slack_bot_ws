defmodule SlackBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :slack_bot_ws,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {SlackBot.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:websockex, "~> 0.4"},
      {:req, "~> 0.4"},
      {:jason, "~> 1.4"}
    ]
  end
end
