defmodule SlackBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :slack_bot_ws,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/dfeuerbach/slack_bot_ws",
      description: description(),
      package: package(),
      deps: deps(),
      docs: [
        main: "readme",
        source_ref: "master",
        source_url: "https://github.com/dfeuerbach/slack_bot_ws",
        extras: [
          "README.md",
          "docs/getting_started.md",
          "docs/rate_limiting.md",
          "docs/slash_grammar.md",
          "docs/diagnostics.md",
          "docs/telemetry_dashboard.md",
          "CHANGELOG.md"
        ],
        groups_for_extras: [
          Guides: [
            "docs/getting_started.md",
            "docs/rate_limiting.md",
            "docs/slash_grammar.md",
            "docs/diagnostics.md",
            "docs/telemetry_dashboard.md"
          ]
        ],
        assets: %{"docs/images" => "docs/images"}
      ]
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
      {:finch, "~> 0.20"},
      {:websockex, "~> 0.4"},
      {:req, "~> 0.4"},
      {:jason, "~> 1.4"},
      {:nimble_parsec, "~> 1.4"},
      {:redix, "~> 1.2", optional: true},
      {:igniter, "~> 0.6", optional: true},
      {:ex_doc, "~> 0.39.1", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    Production-ready Slack bot framework for Socket Mode. Tier-aware rate limiting, \
    deterministic slash-command parsing, and full observability—out of the box.
    """
  end

  defp package do
    [
      maintainers: ["Douglas Feuerbach"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/dfeuerbach/slack_bot_ws",
        "Changelog" => "https://github.com/dfeuerbach/slack_bot_ws/blob/master/CHANGELOG.md"
      },
      files: ~w(lib docs mix.exs README.md LICENSE CHANGELOG.md AGENTS.md)
    ]
  end

  defp elixirc_paths(:dev), do: ["lib", "examples/basic_bot/lib"]
  defp elixirc_paths(:test), do: ["lib", "examples/basic_bot/lib"]
  defp elixirc_paths(_), do: ["lib"]
end
