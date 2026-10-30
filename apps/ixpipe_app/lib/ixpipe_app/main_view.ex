defmodule IxpipeApp.MainView do
  @moduledoc """
  The main window: a home screen listing the workflows in a directory, and a
  canvas to build, wire, save and run one.

  Args: `:dir` (the workflows directory) and, optionally, `:path` to open.
  """
  use Baguette.View

  alias Explorer.DataFrame
  alias IxpipeCore.{Edit, Spec, Tools}

  @node_width 180
  @port_y 24
  @palette ~w(input_csv select filter formula sort join summarize output_csv)

  def mount(args) do
    dir = Keyword.fetch!(args, :dir)
    File.mkdir_p!(dir)

    assigns = %{
      dir: dir,
      files: [],
      error: nil,
      path: nil,
      spec: nil,
      from: nil,
      status: nil,
      rows: %{}
    }

    case args[:path] do
      nil -> {:ok, home(assigns)}
      path -> {:ok, open(assigns, path)}
    end
  end

  def render(%{spec: nil} = assigns) do
    ~H"""
    <div class="size-full flex-col gap-4 p-6 bg-background text-foreground">
      <div class="flex-row items-center justify-between">
        <text class="text-2xl font-bold">Workflows</text>
        <button class="px-4 py-2 rounded-md bg-primary text-primary-foreground hover:opacity-90" phx-click="new"
          aria-label="New workflow">New workflow</button>
      </div>
      <text :if={@error} class="text-destructive">{@error}</text>
      <text :if={@files == []} class="text-muted-foreground">No workflows in {@dir} yet.</text>
      <div class="flex-col gap-2">
        <button :for={file <- @files} class="p-3 rounded-md border border-border hover:bg-muted"
          phx-click="open" phx-value-file={file} aria-label={"Open #{file}"}>{file}</button>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="size-full flex-col bg-background text-foreground">
      <div class="flex-row items-center gap-3 p-3 bg-muted">
        <button class="px-3 py-1 rounded-md border border-border" phx-click="back" aria-label="Back">Back</button>
        <text class="font-bold">{Path.basename(@path)}</text>
        <button class="px-3 py-1 rounded-md border border-border" phx-click="save" aria-label="Save">Save</button>
        <button class="px-3 py-1 rounded-md bg-primary text-primary-foreground" phx-click="run" aria-label="Run">Run</button>
        <text :if={@status}>{@status}</text>
      </div>
      <div class="flex-row flex-1">
        <div class="flex-col gap-1 p-3 w-[160px] bg-muted">
          <text class="text-sm text-muted-foreground">Tools</text>
          <button :for={tool <- palette()} class="px-2 py-1 rounded-md hover:bg-muted text-sm"
            phx-click="add" phx-value-tool={tool} aria-label={"Add #{tool}"}>{tool}</button>
        </div>
        <div class="relative flex-1 overflow-hidden bg-canvas">
          <line :for={{from, to} <- edges(@spec)} x1={from.position["x"] + node_width()}
            y1={from.position["y"] + port_y()} x2={to.position["x"]} y2={to.position["y"] + port_y()}
            class="stroke-muted-foreground" />
          <div :for={node <- @spec.nodes} aria-label={node.id} phx-drag="move" phx-value-id={node.id}
            class={"absolute left-[#{node.position["x"]}px] top-[#{node.position["y"]}px] w-[#{node_width()}px] flex-col gap-1 p-2 rounded-md border bg-background " <> if(@from == node.id, do: "border-primary", else: "border-border")}>
            <div class="flex-row items-center justify-between">
              <text class="font-bold">{node.id}</text>
              <button class="px-1 text-xs" phx-click="remove" phx-value-id={node.id}
                aria-label={"Remove #{node.id}"}>x</button>
            </div>
            <text class="text-xs text-muted-foreground">{Tools.name(node.tool)}</text>
            <text :if={@rows[node.id]} class="text-xs">{@rows[node.id]} rows</text>
            <div class="flex-row gap-1">
              <button :for={port <- node.tool.inputs()} class="px-1 text-xs rounded-sm border border-border"
                phx-click="connect_to" phx-value-id={node.id} phx-value-port={port}
                aria-label={"Connect to #{node.id} #{port}"}>{port}</button>
              <button class="px-1 text-xs rounded-sm border border-border" phx-click="connect_from"
                phx-value-id={node.id} aria-label={"Connect from #{node.id}"}>out</button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def handle_event("open", %{"file" => file}, assigns),
    do: {:noreply, open(assigns, Path.join(assigns.dir, file))}

  def handle_event("new", _values, assigns) do
    path =
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(&Path.join(assigns.dir, "untitled-#{&1}.yaml"))
      |> Enum.find(&(not File.exists?(&1)))

    File.write!(path, Spec.to_yaml(%Spec{}))
    {:noreply, open(assigns, path)}
  end

  def handle_event("back", _values, assigns), do: {:noreply, home(assigns)}

  def handle_event("save", _values, assigns) do
    File.write!(assigns.path, Spec.to_yaml(assigns.spec))
    {:noreply, %{assigns | status: "Saved"}}
  end

  def handle_event("add", %{"tool" => tool}, assigns) do
    at = %{
      "x" => 40 + 30 * length(assigns.spec.nodes),
      "y" => 40 + 30 * length(assigns.spec.nodes)
    }

    {:noreply, edit(assigns, &Edit.add_node(&1, tool, at))}
  end

  def handle_event("move", %{"id" => id, "dx" => dx, "dy" => dy}, assigns),
    do: {:noreply, edit(assigns, &Edit.move_node(&1, id, round(dx), round(dy)))}

  def handle_event("remove", %{"id" => id}, assigns),
    do: {:noreply, edit(assigns, &Edit.remove_node(&1, id))}

  def handle_event("connect_from", %{"id" => id}, assigns),
    do: {:noreply, %{assigns | from: id, status: "Connecting from #{id}"}}

  def handle_event("connect_to", %{"id" => id, "port" => port}, %{from: from} = assigns)
      when is_binary(from) and from != id do
    {:noreply, %{edit(assigns, &Edit.connect(&1, from, id, port)) | status: nil}}
  end

  def handle_event("connect_to", _values, assigns),
    do: {:noreply, %{assigns | status: "Pick a node's out first"}}

  def handle_event("run", _values, assigns) do
    status =
      with {:ok, spec} <- Spec.validate(assigns.spec),
           {:ok, results} <- IxpipeCore.run(spec) do
        {:ok, Map.new(results, fn {id, df} -> {id, DataFrame.n_rows(df)} end)}
      end

    case status do
      {:ok, rows} ->
        {:noreply, %{assigns | status: "Run succeeded", rows: rows}}

      {:error, {:node_failed, id, msg}} ->
        {:noreply, %{assigns | status: "#{id} failed: #{msg}", rows: %{}}}

      {:error, reason} ->
        {:noreply, %{assigns | status: Spec.format_error(reason), rows: %{}}}
    end
  end

  defp home(assigns) do
    files =
      assigns.dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".yaml")) |> Enum.sort()

    %{assigns | files: files, spec: nil, path: nil, from: nil, status: nil, rows: %{}}
  end

  defp open(assigns, path) do
    case path |> File.read!() |> Spec.decode() do
      {:ok, spec} ->
        %{assigns | spec: place(spec), path: path, error: nil, status: nil, rows: %{}}

      {:error, reason} ->
        %{home(assigns) | error: "#{Path.basename(path)}: #{Spec.format_error(reason)}"}
    end
  end

  # Nodes without a saved position get one, so dragging starts where they show.
  defp place(spec) do
    nodes =
      spec.nodes
      |> Enum.with_index()
      |> Enum.map(fn
        {%{position: nil} = node, i} -> %{node | position: %{"x" => 40 + 220 * i, "y" => 40}}
        {node, _} -> node
      end)

    %{spec | nodes: nodes}
  end

  defp edit(assigns, fun), do: %{assigns | spec: fun.(assigns.spec), from: nil, rows: %{}}

  defp edges(spec) do
    by_id = Map.new(spec.nodes, &{&1.id, &1})
    for node <- spec.nodes, {_port, from} <- node.inputs, by_id[from], do: {by_id[from], node}
  end

  defp palette, do: @palette
  defp node_width, do: @node_width
  defp port_y, do: @port_y
end
