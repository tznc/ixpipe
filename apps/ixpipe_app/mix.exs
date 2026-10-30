defmodule IxpipeApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :ixpipe_app,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {IxpipeApp.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ixpipe_core, in_umbrella: true},
      {:playwright_ex, "~> 0.15", only: :test},
      {:websockex, "~> 0.4", only: :test},
      {:baguette, github: "ziinc/baguette", ref: "0880ab95eb96a28f671a4e2ec07823ce921d2a60"}
    ]
  end
end
