defmodule Claptrap.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Claptrap.Config.validate!()

    children = [
      Claptrap.Repo,
      {Registry, keys: :unique, name: Claptrap.Registry},
      {Phoenix.PubSub, name: Claptrap.PubSub},
      Claptrap.Consumer.Supervisor,
      Claptrap.Producer.Supervisor,
      Claptrap.Extractor.Supervisor,
      {Bandit, plug: Claptrap.API.Plug, port: port()}
    ]

    opts = [strategy: :one_for_one, name: Claptrap.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp port do
    Application.get_env(:claptrap, :port, 4000)
  end
end
