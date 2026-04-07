defmodule Egghead.MixProject do
  use Mix.Project

  def project do
    [
      app: :egghead,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Egghead.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:yaml_elixir, "~> 2.11"},
      {:file_system, "~> 1.0"},
      {:earmark, "~> 1.4"},
      {:nimble_parsec, "~> 1.4"},
      {:exqlite, "~> 0.27"},
      {:jason, "~> 1.4"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.5"},
      # Pinned to fix commit: append!/2 was silently discarding auto-flushed data,
      # causing blank screens on wide terminals. PR #16, before MDEx was added.
      {:term_ui, github: "pcharbon70/term_ui", ref: "a2db141"}
    ]
  end

  defp package do
    [
      licenses: ["AGPL-3.0-or-later"],
      links: %{}
    ]
  end
end
