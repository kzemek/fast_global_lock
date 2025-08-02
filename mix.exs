defmodule FastGlobalLock.MixProject do
  use Mix.Project

  def project do
    [
      app: :fast_global_lock,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:benchee, "~> 1.4", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
