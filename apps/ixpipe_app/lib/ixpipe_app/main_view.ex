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
  alias IxpipeCore.{Config, Edit, Spec, Tools}

  @node_width 200
  @port_y 24
  @toast_ms 6_000
  @preview_rows 50
  @palette ~w(input_csv select filter formula sort join union summarize sample unique output_csv)

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
      rows: %{},
      previews: %{},
      selected: nil,
      drafts: %{},
      errors: %{},
      formula_rows: 1
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
    assigns = Map.put(assigns, :node, Enum.find(assigns.spec.nodes, &(&1.id == assigns.selected)))

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
        <div class="flex-col flex-1">
        <div class="relative flex-1 overflow-hidden bg-canvas">
          <.empty_state :if={@spec.nodes == []} title="This workflow is empty">
            Add a tool from the list on the left.
          </.empty_state>
          <%!-- The surface is as large as the furthest node, so the canvas
            scrolls to every one. --%>
          <div class="absolute left-[0px] top-[0px] size-full overflow-scroll" aria-label="Canvas">
          <div class={"relative #{surface(@spec)}"} aria-label="Canvas surface">
          <line :for={{from, to, slot} <- edges(@spec)} curve x1={from.position["x"] + node_width()}
            y1={from.position["y"] + port_y()} x2={to.position["x"]}
            y2={to.position["y"] + port_y() + 12 * slot} class="stroke-muted-foreground" />
          <div :for={node <- @spec.nodes} aria-label={node.id} phx-drag="move" phx-value-id={node.id}
            class={"absolute left-[#{node.position["x"]}px] top-[#{node.position["y"]}px] w-[#{node_width()}px] flex-col gap-2 p-3 rounded-md border " <> card_state(node.id, @selected, @from)}>
            <div class="flex-row items-center justify-between gap-2">
              <.button variant={:quiet} size={:sm} class="px-0" phx-click="select" phx-value-id={node.id}
                aria-label={"Select #{node.id}"}><.section>{node.id}</.section></.button>
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
          </div>
          </div>
          <%!-- Over the canvas, so status never moves the layout; the opaque
            backing keeps the callout's tint from showing the canvas through. --%>
          <div :if={@status} class="absolute left-[16px] bottom-[16px] w-[420px] rounded-md bg-background shadow-md">
            <.callout tone={elem(@status, 0)} title={elem(@status, 1)}>{elem(@status, 2)}</.callout>
          </div>
        </div>
        <div class="h-px w-full bg-border" />
        <.results node={@node} preview={@node && @previews[@node.id]} />
        </div>
        <div class="w-px h-full bg-border" />
        <.properties node={@node} drafts={@drafts} errors={@errors} formula_rows={@formula_rows} />
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

    assigns = edit(assigns, &Edit.add_node(&1, tool, at))
    {:noreply, select(assigns, List.last(assigns.spec.nodes).id)}
  end

  def handle_event("select", %{"id" => id}, assigns), do: {:noreply, select(assigns, id)}

  # Text settings: the form sends every value with the one that changed as
  # _target. Formula rows are one setting, a line each.
  def handle_event("config", %{"_target" => "formula_" <> _} = values, assigns) do
    rows =
      for {"formula_" <> n, text} <- values, do: {String.to_integer(n), text}

    rows = rows |> Enum.sort() |> Enum.map(&elem(&1, 1))
    text = rows |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
    {:noreply, configure(assigns, "formulas", text, rows)}
  end

  def handle_event("config", %{"_target" => key} = values, assigns) do
    text = values[key] || ""
    {:noreply, configure(assigns, key, text, text)}
  end

  def handle_event("choose", %{"key" => key, "value" => value}, assigns),
    do: {:noreply, configure(assigns, key, value, nil)}

  def handle_event("switch", %{"key" => key, "checked" => checked}, assigns),
    do: {:noreply, configure(assigns, key, to_string(checked), nil)}

  def handle_event("add_formula", _values, assigns),
    do: {:noreply, %{assigns | formula_rows: formula_rows(assigns) + 1}}

  def handle_event("move", %{"id" => id, "dx" => dx, "dy" => dy}, assigns),
    do: {:noreply, edit(assigns, &Edit.move_node(&1, id, round(dx), round(dy)))}

  def handle_event("remove", %{"id" => id}, assigns) do
    assigns = edit(assigns, &Edit.remove_node(&1, id))
    {:noreply, if(assigns.selected == id, do: select(assigns, nil), else: assigns)}
  end

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
        rows = Map.new(results, fn {id, df} -> {id, DataFrame.n_rows(df)} end)
        {:ok, rows, Map.new(results, fn {id, df} -> {id, preview(df)} end)}
      end

    case result do
      {:ok, rows, previews} ->
        status =
          {:success, "Run succeeded", "Select a tool to see its rows in Results."}

        {:noreply, %{assigns | status: status, rows: rows, previews: previews}}

      {:error, {:node_failed, id, message}} ->
        status = {:danger, "#{id} failed.", "#{message} Fix its config and run again."}
        {:noreply, %{assigns | status: status, rows: %{}, previews: %{}}}

      {:error, reason} ->
        status = {:danger, "The workflow can't run yet.", Spec.format_error(reason)}
        {:noreply, %{assigns | status: status, rows: %{}, previews: %{}}}
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
    do: %{assigns | spec: fun.(assigns.spec), from: nil, status: nil, rows: %{}, previews: %{}}

  defp select(assigns, id),
    do: %{assigns | selected: id, drafts: %{}, errors: %{}, formula_rows: 1}

  # Applies a setting typed or chosen in the properties panel. What was typed
  # stays as a draft, so the input never rewrites it; an invalid value shows
  # why and leaves the workflow as it was.
  defp configure(assigns, key, text, draft) do
    drafts = if draft, do: Map.put(assigns.drafts, key, draft), else: assigns.drafts

    case Edit.set_config(assigns.spec, assigns.selected, key, text) do
      {:ok, spec} ->
        assigns = edit(assigns, fn _ -> spec end)
        %{assigns | drafts: drafts, errors: Map.delete(assigns.errors, key)}

      {:error, message} ->
        %{assigns | drafts: drafts, errors: Map.put(assigns.errors, key, message)}
    end
  end

  defp formula_rows(assigns) do
    node = Enum.find(assigns.spec.nodes, &(&1.id == assigns.selected))
    lines = formula_lines(node, assigns.drafts)
    max(length(lines), assigns.formula_rows)
  end

  # The first rows of a tool's output, as strings, for the results grid.
  defp preview(df) do
    columns = DataFrame.names(df)
    head = df |> DataFrame.head(@preview_rows) |> DataFrame.to_columns()
    rows = Enum.zip_with(Enum.map(columns, &head[&1]), &Enum.map(&1, fn v -> cell(v) end))

    numeric =
      for {name, type} <- DataFrame.dtypes(df),
          match?({kind, _} when kind in [:s, :u, :f], type),
          do: name

    %{columns: columns, rows: rows, total: DataFrame.n_rows(df), numeric: numeric}
  end

  defp cell(nil), do: "—"
  defp cell(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp cell(value), do: to_string(value)

  # Each edge with its input's slot on the target, so a join's left and
  # right wires arrive one above the other.
  defp edges(spec) do
    by_id = Map.new(spec.nodes, &{&1.id, &1})

    for node <- spec.nodes,
        {port, slot} <- Enum.with_index(node.tool.inputs()),
        from = node.inputs[port],
        by_id[from],
        do: {by_id[from], node, slot}
  end

  defp surface(spec) do
    {w, h} =
      Enum.reduce(spec.nodes, {0, 0}, fn %{position: %{"x" => x, "y" => y}}, {w, h} ->
        {max(w, x + @node_width + 40), max(h, y + 160)}
      end)

    "w-[#{w}px] h-[#{h}px]"
  end

  defp card_state(id, _selected, id), do: "border-primary bg-primary/12"
  defp card_state(id, id, _from), do: "border-primary bg-background"
  defp card_state(_id, _selected, _from), do: "border-border bg-background"

  ## Panels

  attr(:node, :map, default: nil)
  attr(:preview, :map, default: nil)

  defp results(assigns) do
    ~H"""
    <section class="flex-col gap-2 p-4 h-[240px]" aria-label="Results">
      <div class="flex-row items-center gap-2">
        <.section>Results</.section>
        <.caption :if={@preview}>{@node.id} · {plural(@preview.total, "row")}{if @preview.total > length(@preview.rows), do: ", first #{length(@preview.rows)} shown"}</.caption>
      </div>
      <.caption :if={!@node}>Select a tool to see its results.</.caption>
      <.caption :if={@node && !@preview}>Run the workflow to see this tool's results.</.caption>
      <div :if={@preview} class="flex-col flex-1 overflow-scroll">
        <table class="flex-col">
          <tr class="flex-row py-1">
            <th :for={column <- @preview.columns} class="w-[140px] px-2">
              <.label class={if column in @preview.numeric, do: "text-right", else: ""}>{column}</.label>
            </th>
          </tr>
          <div class="h-px bg-border" />
          <tr :for={row <- @preview.rows} class="flex-row py-1">
            <td :for={{value, column} <- Enum.zip(row, @preview.columns)} class="w-[140px] px-2">
              <.body class={cell_class(value, column in @preview.numeric)}>{value}</.body>
            </td>
          </tr>
        </table>
      </div>
    </section>
    """
  end

  defp cell_class(value, numeric) do
    muted = if value in ["—", "0"], do: "text-muted-foreground ", else: ""
    muted <> if(numeric, do: "text-right", else: "")
  end

  attr(:node, :map, default: nil)
  attr(:drafts, :map, required: true)
  attr(:errors, :map, required: true)
  attr(:formula_rows, :integer, required: true)

  defp properties(assigns) do
    ~H"""
    <aside class="flex-col gap-6 p-4 w-[320px] overflow-y-scroll" aria-label="Configuration">
      <.empty_state :if={!@node} title="Nothing selected">Select a tool to configure it.</.empty_state>
      <div :if={@node} class="flex-col gap-1">
        <.section>{@node.id}</.section>
        <.caption>{tool_label(Tools.name(@node.tool))}</.caption>
      </div>
      <.caption :if={@node && @node.tool.fields() == []}>This tool has no settings.</.caption>
      <form :if={@node} phx-change="config" aria-label="Settings" class="flex-col gap-3">
        <.field :for={field <- @node.tool.fields()} field={field} node={@node} drafts={@drafts}
          error={@errors[field.key]} formula_rows={@formula_rows} />
      </form>
    </aside>
    """
  end

  attr(:field, :map, required: true)
  attr(:node, :map, required: true)
  attr(:drafts, :map, required: true)
  attr(:error, :string, default: nil)
  attr(:formula_rows, :integer, required: true)

  defp field(%{field: %{type: :bool}} = assigns) do
    ~H"""
    <div class="flex-row items-center gap-2">
      <input type="checkbox" checked={@node.config[@field.key] == true} phx-click="switch"
        phx-value-key={@field.key} aria-label={@field.label} />
      <.body>{@field.label}</.body>
    </div>
    """
  end

  defp field(%{field: %{type: :choice}} = assigns) do
    ~H"""
    <div class="flex-col gap-1">
      <.label>{@field.label}</.label>
      <div class="flex-row flex-wrap gap-1">
        <.button :for={option <- @field.options} size={:sm} phx-click="choose" phx-value-key={@field.key}
          phx-value-value={option} aria-label={"#{@field.label} #{option}"}
          class={if chosen(@field, @node) == option, do: "border-primary bg-primary/12", else: ""}>
          {option}
        </.button>
      </div>
      <.caption :if={@field[:hint]}>{@field.hint}</.caption>
    </div>
    """
  end

  defp field(%{field: %{type: :formulas}} = assigns) do
    lines = formula_lines(assigns.node, assigns.drafts)
    count = max(length(lines), assigns.formula_rows)

    assigns =
      Map.put(
        assigns,
        :lines,
        Enum.with_index(lines ++ List.duplicate("", count - length(lines)), 1)
      )

    ~H"""
    <div class="flex-col gap-1">
      <.label>{@field.label}</.label>
      <input :for={{line, i} <- @lines} name={"formula_#{i}"} value={line}
        placeholder="name = expression" aria-label={"Formula #{i}"} class="w-full" />
      <.caption :if={@error} class="text-danger">{@error}</.caption>
      <.caption :if={!@error && @field[:hint]}>{@field.hint}</.caption>
      <div class="flex-row">
        <.button size={:sm} phx-click="add_formula" aria-label="Add a formula">Add a formula</.button>
      </div>
    </div>
    """
  end

  defp field(assigns) do
    ~H"""
    <div class="flex-col gap-1">
      <div class="flex-row items-center gap-2">
        <.label>{@field.label}</.label>
        <.caption :if={@field[:optional]}>Optional</.caption>
      </div>
      <input name={@field.key} value={@drafts[@field.key] || Config.format(@field, @node.config[@field.key])}
        placeholder={@field[:hint]} aria-label={@field.label} class="w-full" />
      <.caption :if={@error} class="text-danger">{@error}</.caption>
      <.caption :if={!@error && @field[:hint]}>{@field.hint}</.caption>
    </div>
    """
  end

  defp chosen(field, node), do: node.config[field.key] || hd(field.options)

  defp formula_lines(nil, _drafts), do: []

  defp formula_lines(node, drafts) do
    case drafts["formulas"] do
      nil ->
        field = Enum.find(node.tool.fields(), &(&1.key == "formulas"))

        node.config["formulas"]
        |> then(&Config.format(field, &1))
        |> String.split("\n", trim: true)

      rows ->
        rows
    end
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
