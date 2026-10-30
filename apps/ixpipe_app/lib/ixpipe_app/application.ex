defmodule IxpipeApp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:ixpipe_app, :main_window, true) do
        [{IxpipeApp.MainView, window: 0, theme: IxpipeApp.Theme, args: main_args()}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: IxpipeApp.Supervisor)
  end

  # IXPIPE_HOME holds the workflows (default ~/ixpipe); IXPIPE_WORKFLOW opens
  # one at startup.
  defp main_args do
    dir = System.get_env("IXPIPE_HOME") || Path.expand("~/ixpipe")
    [dir: dir] ++ if(path = System.get_env("IXPIPE_WORKFLOW"), do: [path: path], else: [])
  end
end
