defmodule RockstatFront.MixProject do
  use Mix.Project

  def project do
    [
      app: :rockstat_front,
      version: "4.4.0",
      elixir: "~> 1.15",
      package: [licenses: ["Apache-2.0"]],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {RockstatFront.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:redix, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},
      {:mime, "~> 2.0"}
    ]
  end
end
