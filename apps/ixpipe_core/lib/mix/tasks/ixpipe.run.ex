defmodule Mix.Tasks.Ixpipe.Run do
  @shortdoc "Runs a workflow headlessly"
  @moduledoc """
  Runs a workflow without the app, as `IxpipeCore.CLI` does:

      mix ixpipe.run sales.yaml [--json] [--output-dir DIR]

  Exits non-zero when the workflow fails (1) or on bad usage (2).
  """
  use Mix.Task

  @impl true
  def run(argv) do
    # Only the engine: the app would open its window.
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ixpipe_core)

    case IxpipeCore.CLI.main(["run" | argv]) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end
end
