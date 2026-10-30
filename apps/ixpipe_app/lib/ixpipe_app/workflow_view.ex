defmodule IxpipeApp.WorkflowView do
  @moduledoc "Shows a workflow file's nodes and runs it."
  use Baguette.View

  alias Explorer.DataFrame
  alias IxpipeCore.Spec

  def mount(args) do
    path = Keyword.fetch!(args, :path)

    assigns =
      case path |> File.read!() |> Spec.parse() do
        {:ok, spec} -> %{spec: spec, error: nil, status: nil, rows: %{}}
        {:error, reason} -> %{spec: nil, error: Spec.format_error(reason), status: nil, rows: %{}}
      end

    {:ok, assigns}
  end

  def render(%{spec: nil} = assigns) do
    ~H"""
    <div class="size-full flex-col p-6 bg-background text-foreground">
      <text class="text-destructive">{@error}</text>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="size-full flex-col gap-4 p-6 bg-background text-foreground">
      <div class="flex-row items-center gap-4">
        <text class="text-2xl font-bold">{@spec.name || "Untitled workflow"}</text>
        <button class="px-4 py-2 rounded-md bg-primary hover:opacity-90" phx-click="run"
          aria-label="Run">Run</button>
        <text :if={@status}>{@status}</text>
      </div>
      <div class="flex-col gap-2">
        <div :for={node <- @spec.nodes} class="flex-row gap-3 p-3 rounded-md border border-border">
          <text class="font-bold">{node.id}</text>
          <text class="text-muted-foreground">{tool_name(node.tool)}</text>
          <text :if={@rows[node.id]}>{@rows[node.id]} rows</text>
        </div>
      </div>
    </div>
    """
  end

  def handle_event("run", _values, assigns) do
    case IxpipeCore.run(assigns.spec) do
      {:ok, results} ->
        rows = Map.new(results, fn {id, df} -> {id, DataFrame.n_rows(df)} end)
        {:noreply, %{assigns | status: "Run succeeded", rows: rows}}

      {:error, {:node_failed, id, message}} ->
        {:noreply, %{assigns | status: "#{id} failed: #{message}", rows: %{}}}
    end
  end

  defp tool_name(tool), do: IxpipeCore.Tools.name(tool)
end
