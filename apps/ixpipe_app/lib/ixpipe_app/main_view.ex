defmodule IxpipeApp.MainView do
  @moduledoc """
  The main window: a home screen listing the workflows in a directory, and a
  canvas to build, wire, save and run one. Built from `IxpipeApp.Components`
  to the design language in AGENTS.md.

  Args: `:dir` (the workflows directory) and, optionally, `:path` to open.
  """
  use Baguette.View
  import IxpipeApp.Components

  alias Explorer.DataFrame
  alias IxpipeCore.{Edit, Spec, Tools}

  @node_width 200
  @port_y 24
  @toast_ms 6_000
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
      toast: nil,
      rows: %{}
    }

    case args[:path] do
      nil -> {:ok, home(assigns)}
      path -> {:ok, open(assigns, path)}
    end
  end

  def render(%{spec: nil} = assigns) do
    ~H"""
    <div class="relative size-full flex-col gap-6 p-6 bg-background text-foreground">
      <div class="flex-row items-center justify-between">
        <.title>Workflows</.title>
        <.button variant={:primary} phx-click="new" aria-label="New workflow">New workflow</.button>
      </div>
      <.callout :if={@error} tone={:danger} title="This workflow can't be opened.">{@error}</.callout>
      <.empty_state :if={@files == []} title="No workflows yet">
        Create one with New workflow. Workflows are saved in {@dir}.
      </.empty_state>
      <ul :if={@files != []} aria-label="Workflows" class="flex-col gap-1">
        <li :for={{file, modified} <- @files} class="flex-row items-center justify-between gap-3">
          <.button variant={:quiet} phx-click="open" phx-value-file={file} aria-label={"Open #{file}"}>
            {file}
          </.button>
          <.caption>{modified}</.caption>
        </li>
      </ul>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="relative size-full flex-col bg-background text-foreground">
      <div class="flex-row items-center justify-between gap-3 px-4 py-3">
        <div class="flex-col gap-1">
          <.breadcrumb crumbs={[{"Workflows", "back"}, Path.basename(@path)]} />
          <.title>{@spec.name || Path.rootname(Path.basename(@path))}</.title>
        </div>
        <div class="flex-row items-center gap-2">
          <.button phx-click="save" aria-label="Save workflow">Save workflow</.button>
          <.button variant={:primary} phx-click="run" aria-label="Run workflow">Run workflow</.button>
        </div>
      </div>
      <div class="h-px w-full bg-border" />
      <div class="flex-row flex-1">
        <nav class="flex-col gap-1 p-3 w-[180px] bg-sidebar" aria-label="Tools">
          <.label class="px-3 pb-1">Tools</.label>
          <.button :for={tool <- palette()} variant={:quiet} phx-click="add" phx-value-tool={tool}
            aria-label={"Add #{tool}"}>{tool_label(tool)}</.button>
        </nav>
        <div class="w-px h-full bg-border" />
        <div class="relative flex-1 overflow-hidden bg-canvas">
          <.empty_state :if={@spec.nodes == []} title="This workflow is empty">
            Add a tool from the list on the left.
          </.empty_state>
          <line :for={{from, to} <- edges(@spec)} x1={from.position["x"] + node_width()}
            y1={from.position["y"] + port_y()} x2={to.position["x"]} y2={to.position["y"] + port_y()}
            class="stroke-muted-foreground" />
          <div :for={node <- @spec.nodes} aria-label={node.id} phx-drag="move" phx-value-id={node.id}
            class={"absolute left-[#{node.position["x"]}px] top-[#{node.position["y"]}px] w-[#{node_width()}px] flex-col gap-2 p-3 rounded-md border " <> if(@from == node.id, do: "border-primary bg-primary/12", else: "border-border bg-background")}>
            <div class="flex-row items-center justify-between gap-2">
              <.section>{node.id}</.section>
              <.button variant={:danger} size={:sm} phx-click="remove" phx-value-id={node.id}
                aria-label={"Remove #{node.id}"}>Remove</.button>
            </div>
            <div class="flex-row items-center gap-2">
              <.caption>{tool_label(Tools.name(node.tool))}</.caption>
              <.status_badge :if={@rows[node.id]} tone={:success}>{plural(@rows[node.id], "row")}</.status_badge>
            </div>
            <div class="flex-row gap-1">
              <.button :for={port <- node.tool.inputs()} size={:sm} phx-click="connect_to"
                phx-value-id={node.id} phx-value-port={port} aria-label={"Connect to #{node.id} #{port}"}>
                {port}
              </.button>
              <.button size={:sm} phx-click="connect_from" phx-value-id={node.id}
                aria-label={"Connect from #{node.id}"}>out</.button>
            </div>
          </div>
          <%!-- Over the canvas, so status never moves the layout; the opaque
            backing keeps the callout's tint from showing the canvas through. --%>
          <div :if={@status} class="absolute left-[16px] bottom-[16px] w-[420px] rounded-md bg-background shadow-md">
            <.callout tone={elem(@status, 0)} title={elem(@status, 1)}>{elem(@status, 2)}</.callout>
          </div>
        </div>
      </div>
      <.toast :if={@toast} message={@toast} />
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
    Process.send_after(self(), :dismiss_toast, @toast_ms)
    {:noreply, %{assigns | toast: "Saved #{Path.basename(assigns.path)}"}}
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

  def handle_event("connect_from", %{"id" => id}, assigns) do
    status = {:info, "Connecting from #{id}", "Choose an input on another node."}
    {:noreply, %{assigns | from: id, status: status}}
  end

  def handle_event("connect_to", %{"id" => id, "port" => port}, %{from: from} = assigns)
      when is_binary(from) and from != id do
    {:noreply, edit(assigns, &Edit.connect(&1, from, id, port))}
  end

  def handle_event("connect_to", _values, assigns) do
    status = {:info, "Choose where the data comes from first.", "Press out on that node."}
    {:noreply, %{assigns | status: status}}
  end

  def handle_event("run", _values, assigns) do
    result =
      with {:ok, spec} <- Spec.validate(assigns.spec),
           {:ok, results} <- IxpipeCore.run(spec) do
        {:ok, Map.new(results, fn {id, df} -> {id, DataFrame.n_rows(df)} end)}
      end

    case result do
      {:ok, rows} ->
        status = {:success, "Run succeeded", "Each node shows how many rows it produced."}
        {:noreply, %{assigns | status: status, rows: rows}}

      {:error, {:node_failed, id, message}} ->
        status = {:danger, "#{id} failed.", "#{message} Fix its config and run again."}
        {:noreply, %{assigns | status: status, rows: %{}}}

      {:error, reason} ->
        status = {:danger, "The workflow can't run yet.", Spec.format_error(reason)}
        {:noreply, %{assigns | status: status, rows: %{}}}
    end
  end

  def handle_info(:dismiss_toast, assigns), do: {:noreply, %{assigns | toast: nil}}

  defp home(assigns) do
    files =
      for file <- assigns.dir |> File.ls!() |> Enum.sort(),
          String.ends_with?(file, ".yaml"),
          do: {file, modified(Path.join(assigns.dir, file))}

    %{assigns | files: files, spec: nil, path: nil, from: nil, status: nil, toast: nil, rows: %{}}
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
        {%{position: nil} = node, i} -> %{node | position: %{"x" => 40 + 240 * i, "y" => 40}}
        {node, _} -> node
      end)

    %{spec | nodes: nodes}
  end

  defp edit(assigns, fun),
    do: %{assigns | spec: fun.(assigns.spec), from: nil, status: nil, rows: %{}}

  defp edges(spec) do
    by_id = Map.new(spec.nodes, &{&1.id, &1})
    for node <- spec.nodes, {_port, from} <- node.inputs, by_id[from], do: {by_id[from], node}
  end

  # Relative within a week ("5 min ago"), a local date after that.
  defp modified(path) do
    %{mtime: mtime} = File.stat!(path, time: :posix)
    seconds = System.os_time(:second) - mtime

    cond do
      seconds < 60 -> "Just now"
      seconds < 3600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> plural(div(seconds, 3600), "hour") <> " ago"
      seconds < 7 * 86_400 -> plural(div(seconds, 86_400), "day") <> " ago"
      true -> mtime |> DateTime.from_unix!() |> DateTime.to_date() |> Date.to_string()
    end
  end

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(n, noun), do: "#{n} #{noun}s"

  @labels %{"input_csv" => "Input CSV", "output_csv" => "Output CSV"}
  defp tool_label(tool), do: Map.get_lazy(@labels, tool, fn -> String.capitalize(tool) end)

  defp palette, do: @palette
  defp node_width, do: @node_width
  defp port_y, do: @port_y
end
