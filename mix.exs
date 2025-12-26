defmodule SlackBot.MixProject do
  use Mix.Project

  def project do
    [
      app: :slack_bot_ws,
      version: "0.1.0-rc.2",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/dfeuerbach/slack_bot_ws",
      source_ref: "v0.1.0-rc.2",
      description: description(),
      package: package(),
      deps: deps(),
      docs: [
        main: "readme",
        source_ref: "v0.1.0-rc.2",
        source_url: "https://github.com/dfeuerbach/slack_bot_ws",
        extras: [
          "README.md",
          "docs/getting_started.md",
          "docs/rate_limiting.md",
          "docs/slash_grammar.md",
          "docs/diagnostics.md",
          "docs/telemetry_dashboard.md",
          "CHANGELOG.md",
          "LICENSE"
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
        assets: %{"docs/images" => "docs/images"},
        filter_modules: fn module, _meta ->
          module
          |> Atom.to_string()
          |> String.starts_with?("Elixir.BasicBot")
          |> Kernel.not()
        end
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
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:nimble_parsec, "~> 1.4"},
      {:redix, "~> 1.2", optional: true},
      {:igniter, "~> 0.7", optional: true},
      {:ex_doc, "~> 0.39.1", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    A framework that solves the complexity of Slack bots—reconnects, backoff, tiered \
    rate limits, slash-command and chat parsing—so you can build the fun bits.
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
      files:
        ~w(lib mix.exs README.md LICENSE CHANGELOG.md AGENTS.md docs/diagnostics.md docs/getting_started.md docs/rate_limiting.md docs/releasing.md docs/slackbot_design.md docs/slash_grammar.md docs/telemetry_dashboard.md)
    ]
  end

  defp elixirc_paths(:dev), do: ["lib", "examples/basic_bot/lib"]
  defp elixirc_paths(:test), do: ["lib", "examples/basic_bot/lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
