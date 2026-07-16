defmodule SquatchMail.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/Axio-Intelligence/Squatch-Mail"

  def project do
    [
      app: :squatch_mail,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "SquatchMail",
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      mod: {SquatchMail.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # Core
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.19"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:plug, "~> 1.16"},
      {:telemetry, "~> 1.2"},

      # Observed, not required: the host app brings its own Swoosh mailer.
      {:swoosh, "~> 1.16", optional: true},

      # SES v2 client + minimal HTTP client for it.
      {:aws, "~> 1.0"},
      {:finch, "~> 0.19"},

      # Installer (added properly once the igniter task ships).
      {:igniter, "~> 0.5", optional: true},

      # Dev/test only
      {:esbuild, "~> 0.8", runtime: false, only: :dev},
      {:tailwind, "~> 0.2", runtime: false, only: :dev},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:bandit, "~> 1.12", only: [:dev, :test]},
      {:floki, "~> 0.36", only: :test},
      # phoenix_live_view's `live/2` test helper requires this (superseding
      # floki for that helper as of phoenix_live_view 1.1+).
      {:lazy_html, "~> 0.1.0", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      dev: "run --no-halt dev.exs",
      "assets.build": ["esbuild squatch_mail", "squatch_mail.copy_css"]
    ]
  end

  defp description do
    "A self-hosted Amazon SES email dashboard for Phoenix apps, shipped as an embeddable Hex package."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib priv/repo/migrations priv/static .formatter.exs mix.exs README.md CHANGELOG.md SECURITY.md CLAUDE.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "SquatchMail",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "SECURITY.md",
        "RESEARCH.md",
        "FEATURES.md",
        "DESIGN.md",
        "LICENSE"
      ]
    ]
  end
end
