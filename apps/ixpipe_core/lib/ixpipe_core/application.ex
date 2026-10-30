defmodule IxpipeCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Runs Script tool workers apart from the run that called them.
      {Task.Supervisor, name: IxpipeCore.TaskSupervisor}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: IxpipeCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
