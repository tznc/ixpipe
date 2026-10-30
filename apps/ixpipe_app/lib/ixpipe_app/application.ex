defmodule IxpipeApp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Until there is an open-file screen, the main window shows the workflow
    # at IXPIPE_WORKFLOW.
    children =
      case System.get_env("IXPIPE_WORKFLOW") do
        nil -> []
        path -> [{IxpipeApp.WorkflowView, window: 0, args: [path: path]}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: IxpipeApp.Supervisor)
  end
end
