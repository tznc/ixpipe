defmodule Mix.Tasks.Ixpipe.Validate do
  @shortdoc "Checks a workflow without running it"
  @moduledoc """
  Checks that a workflow is a runnable DAG, as `IxpipeCore.CLI` does:

      mix ixpipe.validate sales.yaml
  """
  use Mix.Task

  @impl true
  def run(argv) do
    # Only the engine: the app would open its window.
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ixpipe_core)

    case IxpipeCore.CLI.main(["validate" | argv]) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end
end
