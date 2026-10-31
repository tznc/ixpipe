defmodule IxpipeCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :ixpipe_core,
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
      mod: {IxpipeCore.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:runic, "~> 0.1.0-alpha.13"},
      {:yaml_elixir, "~> 2.11"},
      {:jason, "~> 1.4"},
      {:xlsx_reader, "~> 0.8.12"},
      {:elixlsx, "~> 0.6.0"},
      {:rustler, "~> 0.38"},
      {:postgrex, "~> 0.22"},
      {:myxql, "~> 0.8"},
      {:tds, "~> 2.3"}
    ]
  end
end
