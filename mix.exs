defmodule FastGlobalLock.MixProject do
  use Mix.Project

  def project do
    [
      app: :fast_global_lock,
      version: "0.1.1",
      description: "Fast and fair :global-based lock for Elixir",
      package: package(),
      source_url: "https://github.com/kzemek/fast_global_lock",
      homepage_url: "https://github.com/kzemek/fast_global_lock",
      docs: docs(),
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:benchee, "~> 1.4", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38.1", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "FastGlobalLock",
      extras: ["LICENSE", "NOTICE"]
    ]
  end

  defp package do
    [
      links: %{"GitHub" => "https://github.com/kzemek/fast_global_lock"},
      licenses: ["Apache-2.0"]
    ]
  end

  defp dialyzer do
    []
  end

  defp aliases do
    [
      credo: "credo --strict",
      lint: ["credo", "dialyzer"]
    ]
  end
end
