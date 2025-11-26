defmodule SendSlam.MixProject do
  use Mix.Project

  def project do
    [
      app: :send_slam,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {SendSlam.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:gen_stage, "~> 1.0.0"},
      {:evision, "~> 0.2.14"},
      {:bandit, "~> 1.8"},
      {:websock_adapter, "~> 0.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:msgpax, "~> 2.3"},
      {:nx, "~> 0.10.0"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
