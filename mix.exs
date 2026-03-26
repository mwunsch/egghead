defmodule Egghead.MixProject do
  use Mix.Project

  def project do
    [
      app: :egghead,
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
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.5"}
    ]
  end
end
