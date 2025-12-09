defmodule BasicBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :basic_bot,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BasicBot.Application, []}
    ]
  end

  defp deps do
    [
      {:slack_bot_ws, path: "../.."},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
