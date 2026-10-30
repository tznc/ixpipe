defmodule IxpipeApp.MainView do
  @moduledoc """
  The main window: a home screen listing the workflows in a directory, and a
  canvas to build, wire, save and run one. Built from `IxpipeApp.Components`
  to the design language in AGENTS.md.

  Args: `:dir` (the workflows directory) and, optionally, `:path` to open.
  """
  use Baguette.View
  import IxpipeApp.Components

  alias IxpipeCore.{Config, Connections, Edit, Spec, Table, Tools}

  @node_width 200
  @port_y 24
  # A container's padding around its tools, its title bar, and its size when
  # empty or collapsed.
  @box_pad 16
  @box_bar 48
  @box_empty {280, 160}
  @comment_width 200
  @toast_ms 6_000
  @zooms [50, 75, 100, 125, 150]
  @history 100
  @preview_rows 50
  # Narrower than this (a phone in portrait), the window shows one pane at
  # a time: Canvas, Properties or Results.
  @phone_width 640
  @panes [{"canvas", "Canvas"}, {"properties", "Properties"}, {"results", "Results"}]
  # The ribbon's tabs: Home edits and views the workflow; the rest hold the
  # tools, by category, in labelled groups.
  @ribbon [
    {"home", "Home", []},
    {"inout", "In/Out",
     [
       {"Input", ~w(input_csv input_excel input_parquet input_sqlite input_postgres)},
       {"Output", ~w(output_csv output_excel output_parquet output_sqlite)}
     ]},
    {"prepare", "Preparation",
     [
       {"Columns", ~w(select formula data_cleansing)},
       {"Rows", ~w(filter sort sample unique)}
     ]},
    {"join", "Join", [{"Combine", ~w(join union)}]},
    {"parse", "Parse", [{"Split", ~w(text_to_columns regex)}]},
    {"transform", "Transform",
     [{"Aggregate", ~w(summarize)}, {"Reshape", ~w(cross_tab transpose)}]}
  ]

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
      skipped: [],
      selected: nil,
      output: nil,
      drafts: %{},
      errors: %{},
      formula_rows: 1,
      past: [],
      future: [],
      last_step: nil,
      zoom: 100,
      pan: {0, 0},
      tab: "home",
      width: nil,
      height: nil,
      pane: "canvas"
    }

    case args[:path] do
      nil -> {:ok, home(assigns)}
      path -> {:ok, open(assigns, path)}
    end
  end

  def render(%{spec: nil} = assigns) do
    assigns = Map.put(assigns, :phone, phone?(assigns))

    ~H"""
    <div class={"relative size-full flex-col gap-6 #{if @phone, do: "p-4", else: "p-6"} bg-background text-foreground"}
      phx-window-resize="resize">
      <div class="flex-row items-center justify-between">
        <.title>Workflows</.title>
        <.button variant={:primary} size={touch(@phone)} phx-click="new" aria-label="New workflow">New workflow</.button>
      </div>
      <.callout :if={@error} tone={:danger} title="This workflow can't be opened.">{@error}</.callout>
      <.empty_state :if={@files == []} title="No workflows yet">
        Create one with New workflow. Workflows are saved in {@dir}.
      </.empty_state>
      <ul :if={@files != []} aria-label="Workflows" class="flex-col gap-1">
        <li :for={{file, modified} <- @files} class="flex-row items-center justify-between gap-3">
          <.button variant={:quiet} size={touch(@phone)} phx-click="open" phx-value-file={file} aria-label={"Open #{file}"}>
            {file}
          </.button>
          <.caption>{modified}</.caption>
        </li>
      </ul>
    </div>
    """
  end

  def render(assigns) do
    assigns =
      Map.merge(assigns, %{
        node: Enum.find(assigns.spec.nodes, &(&1.id == assigns.selected)),
        item: Edit.find(assigns.spec, assigns.selected),
        hidden: hidden(assigns.spec),
        off: off(assigns.spec),
        boxes: boxes(assigns.spec, assigns.zoom, assigns.rows),
        phone: phone?(assigns)
      })

    ~H"""
    <div class="relative size-full flex-col bg-background text-foreground" phx-window-keydown="shortcut"
      phx-window-resize="resize">
      <div class={"flex-row items-center justify-between gap-3 " <> if(@phone, do: "px-4 py-1", else: "px-4 py-3")}>
        <div class={if @phone, do: "flex-col flex-1 min-w-0", else: "flex-col gap-1"}>
          <.breadcrumb crumbs={[{"Workflows", "back"}, Path.basename(@path)]} touch={@phone} />
          <.title>{@spec.name || Path.rootname(Path.basename(@path))}</.title>
        </div>
        <%!-- On a phone, Save and Run keep their place as icon-only buttons. --%>
        <div class={"flex-row items-center shrink-0 " <> if(@phone, do: "gap-1", else: "gap-2")}>
          <.button phx-click="save" icon="save" aria-label="Save workflow" size={touch(@phone, :md)}
            title={"Save workflow (#{shortcut("S")})"}>{if !@phone, do: "Save workflow"}</.button>
          <.button variant={:primary} phx-click="run" icon="play" aria-label="Run workflow" size={touch(@phone, :md)}
            title={"Run workflow (#{shortcut("Enter")})"}>{if !@phone, do: "Run workflow"}</.button>
        </div>
      </div>
      <div class="h-px w-full bg-border" />
      <.ribbon tabs={ribbon_tabs()} selected={@tab} touch={@phone}>
        <%= if @tab == "home" do %>
          <.ribbon_group label="Edit">
            <.button size={touch(@phone, :sm)} variant={:quiet} phx-click="undo" disabled={@past == []} icon="undo-2"
              aria-label="Undo" title={"Undo (#{shortcut("Z")})"}>Undo</.button>
            <.button size={touch(@phone, :sm)} variant={:quiet} phx-click="redo" disabled={@future == []} icon="redo-2"
              aria-label="Redo" title={"Redo (#{shortcut("Shift+Z")})"}>Redo</.button>
          </.ribbon_group>
          <.ribbon_group label="Organise">
            <.button size={touch(@phone, :sm)} variant={:quiet} phx-click="add_container" icon="square-dashed"
              aria-label="Add container" title="Add a container around the selected tool">Container</.button>
            <.button size={touch(@phone, :sm)} variant={:quiet} phx-click="add_comment" icon="message-square-text"
              aria-label="Add comment">Comment</.button>
          </.ribbon_group>
          <.ribbon_group label="View">
            <.button size={touch(@phone, :sm)} variant={:quiet} phx-click="zoom" phx-value-by="-1" icon="zoom-out"
              disabled={@zoom == hd(zooms())} aria-label="Zoom out" title={"Zoom out (#{shortcut("-")})"} />
            <.caption class="w-[40px] text-center">{@zoom}%</.caption>
            <.button size={touch(@phone, :sm)} variant={:quiet} phx-click="zoom" phx-value-by="1" icon="zoom-in"
              disabled={@zoom == List.last(zooms())} aria-label="Zoom in" title={"Zoom in (#{shortcut("=")})"} />
            <.button size={touch(@phone, :sm)} variant={:quiet} phx-click="reset_view" icon="scan" aria-label="Restore view"
              title={"Restore view (#{shortcut("0")})"}>Restore view</.button>
          </.ribbon_group>
        <% else %>
          <.ribbon_group :for={{group, tools} <- ribbon_groups(@tab)} label={group}>
            <.button :for={tool <- tools} size={touch(@phone, :sm)} variant={:quiet} phx-click="add" phx-value-tool={tool}
              icon={tool_icon(tool)} aria-label={"Add #{tool}"}>{command_label(group, tool)}</.button>
          </.ribbon_group>
        <% end %>
      </.ribbon>
      <div class={"relative flex-1 " <> if(@phone, do: "flex-col", else: "flex-row")}>
        <div :if={!@phone || @pane == "canvas"} class="flex-col flex-1">
        <div class="relative flex-1 overflow-hidden bg-canvas">
          <.empty_state :if={@spec.nodes == [] and @spec.containers == [] and @spec.comments == []}
            title="This workflow is empty">
            Add a tool from a ribbon tab above.
          </.empty_state>
          <%!-- The surface is as large as the furthest node, so the canvas
            scrolls to every one. --%>
          <div class="absolute left-[0px] top-[0px] size-full overflow-scroll" aria-label="Canvas">
          <%!-- Dragging the empty surface pans the view; nodes claim their own drags. --%>
          <div class={"relative #{surface(@spec, @zoom, @pan)}"} aria-label="Canvas surface"
            phx-drag="pan">
          <%!-- Containers sit behind the tools they hold; dragging one moves them all. --%>
          <div :for={{c, {x, y, w, h}} <- @boxes} aria-label={c.id} phx-drag="move" phx-value-id={c.id}
            class={"absolute left-[#{at(x, @pan, 0, @zoom)}px] top-[#{at(y, @pan, 1, @zoom)}px] w-[#{scaled(w, @zoom)}px] h-[#{scaled(h, @zoom)}px] flex-col rounded-md border " <>
              box_state(c.id, @selected) <> if(c.disabled, do: " opacity-40", else: "")}>
            <div class="flex-row items-center gap-1 px-2 py-1">
              <.button variant={:quiet} size={:sm} phx-click="collapse" phx-value-id={c.id}
                icon={if c.collapsed, do: "chevron-right", else: "chevron-down"}
                aria-label={"#{if c.collapsed, do: "Expand", else: "Collapse"} #{c.id}"} />
              <.button variant={:quiet} size={:sm} class="px-0" phx-click="select" phx-value-id={c.id}
                aria-label={"Select #{c.id}"}><.section>{box_title(c)}</.section></.button>
              <.status_badge :if={c.disabled}>Disabled</.status_badge>
            </div>
          </div>
          <div :for={c <- @spec.comments} aria-label={c.id} phx-drag="move" phx-value-id={c.id}
            class={"absolute left-[#{at(c.position["x"], @pan, 0, @zoom)}px] top-[#{at(c.position["y"], @pan, 1, @zoom)}px] w-[#{scaled(comment_width(), @zoom)}px] flex-col gap-1 p-2 rounded-md border " <>
              box_state(c.id, @selected)}>
            <.button variant={:quiet} size={:sm} class="px-0" phx-click="select" phx-value-id={c.id}
              aria-label={"Select #{c.id}"} icon="message-square-text" />
            <.body :if={c.text != ""}>{c.text}</.body>
            <.caption :if={c.text == ""}>Empty comment</.caption>
          </div>
          <line :for={{x1, y1, x2, y2} <- wires(@spec, @boxes)} curve
            x1={at(x1, @pan, 0, @zoom)} y1={at(y1, @pan, 1, @zoom)}
            x2={at(x2, @pan, 0, @zoom)} y2={at(y2, @pan, 1, @zoom)}
            class="stroke-muted-foreground" />
          <%!-- A tool's annotation sits under its card. --%>
          <div :for={node <- @spec.nodes} :if={node.id not in @hidden} aria-label={node.id} phx-drag="move" phx-value-id={node.id}
            class={"absolute left-[#{vx(node, @zoom, @pan)}px] top-[#{vy(node, @zoom, @pan)}px] w-[#{scaled(node_width(), @zoom)}px] flex-col gap-1" <>
              if(node.id in @off, do: " opacity-40", else: "")}>
          <div class={"flex-col gap-2 rounded-md border #{if compact?(@zoom), do: "p-2", else: "p-3"} " <> card_state(node.id, @selected, @from)}>
            <div class="flex-row flex-wrap items-center justify-between gap-2">
              <.button variant={:quiet} size={:sm} class="px-0" phx-click="select" phx-value-id={node.id}
                aria-label={"Select #{node.id}"}><.section>{node.id}</.section></.button>
              <.button :if={!compact?(@zoom)} variant={:danger} size={:sm} phx-click="remove"
                phx-value-id={node.id} aria-label={"Remove #{node.id}"}>Remove</.button>
            </div>
            <div class="flex-row items-center gap-2">
              <.caption>{tool_label(Tools.name(node.tool))}</.caption>
              <.status_badge :if={@rows[node.id]} tone={:success}>{plural(@rows[node.id], "row")}</.status_badge>
              <.status_badge :if={node.id in @skipped}>Skipped</.status_badge>
            </div>
            <div :if={multi?(node)} class="flex-row flex-wrap gap-1">
              <.status_badge :for={out <- Tools.outputs(node.tool)} :if={@rows["#{node.id}.#{out}"]}
                tone={:success}>{out} · {plural(@rows["#{node.id}.#{out}"], "row")}</.status_badge>
            </div>
            <%!-- Inputs and outputs on their own labelled rows: a join's left and
              right inputs are not its left and right outputs. --%>
            <div :if={!compact?(@zoom) && node.tool.inputs() != []} class="flex-row flex-wrap items-center gap-1">
              <.caption class="w-[28px]">In</.caption>
              <.button :for={port <- node.tool.inputs()} size={:sm} phx-click="connect_to"
                phx-value-id={node.id} phx-value-port={port} aria-label={"Connect to #{node.id} #{port}"}>
                {port}
              </.button>
            </div>
            <div :if={!compact?(@zoom)} class="flex-row flex-wrap items-center gap-1">
              <.caption class="w-[28px]">Out</.caption>
              <.button :for={{out, ref, label} <- connectors(node)} size={:sm} phx-click="connect_from"
                phx-value-from={ref} aria-label={label}>{out}</.button>
            </div>
          </div>
          <.caption :if={node.annotation} class="px-1">{node.annotation}</.caption>
          </div>
          </div>
          </div>
          <%!-- Top right of the canvas, clear of the header's buttons. --%>
          <.feedback :if={!@phone} toast={@toast} status={@status} phone={false} />
        </div>
        <div :if={!@phone} class="h-px w-full bg-border" />
        <.results :if={!@phone} node={@node} output={@node && output_key(@node, @output)}
          preview={@node && @previews[output_key(@node, @output)]} skipped={@node && @node.id in @skipped} />
        </div>
        <.results :if={@phone && @pane == "results"} node={@node} output={@node && output_key(@node, @output)}
          preview={@node && @previews[output_key(@node, @output)]} skipped={@node && @node.id in @skipped} phone />
        <div :if={!@phone} class="w-px h-full bg-border" />
        <.properties :if={!@phone || @pane == "properties"} node={@node} item={@item} drafts={@drafts} errors={@errors}
          formula_rows={@formula_rows} dir={@dir} phone={@phone} containers={@spec.containers} off={@off} />
        <%!-- On a phone, over whichever pane shows. --%>
        <.feedback :if={@phone} toast={@toast} status={@status} phone />
      </div>
      <.tab_bar :if={@phone} tabs={panes()} selected={@pane} event="pane" label="Panes" />
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

  # With a container selected, the new tool goes inside it.
  def handle_event("add", %{"tool" => tool}, assigns) do
    {at, container} =
      case Edit.find(assigns.spec, assigns.selected) do
        %Spec.Container{} = c -> {inside(assigns.spec, c), c.id}
        _ -> {free_spot(assigns.spec), nil}
      end

    assigns = edit(assigns, &Edit.add_node(&1, tool, at, container))
    {:noreply, select(assigns, List.last(assigns.spec.nodes).id)}
  end

  # With a tool selected, the new container holds it.
  def handle_event("add_container", _values, assigns) do
    held = for %Spec.Node{id: id} <- [Edit.find(assigns.spec, assigns.selected)], do: id
    at = if held == [], do: open_space(assigns.spec, @box_empty), else: free_spot(assigns.spec)
    assigns = edit(assigns, &Edit.add_container(&1, at, held))
    {:noreply, select(assigns, List.last(assigns.spec.containers).id)}
  end

  def handle_event("add_comment", _values, assigns) do
    at = open_space(assigns.spec, {@comment_width, 80})
    assigns = edit(assigns, &Edit.add_comment(&1, at))
    {:noreply, select(assigns, List.last(assigns.spec.comments).id)}
  end

  def handle_event("collapse", %{"id" => id}, assigns) do
    collapsed = match?(%Spec.Container{collapsed: true}, Edit.find(assigns.spec, id))
    {:noreply, edit(assigns, &Edit.set_collapsed(&1, id, not collapsed))}
  end

  def handle_event("disable", %{"id" => id}, assigns) do
    disabled = match?(%{disabled: true}, Edit.find(assigns.spec, id))
    {:noreply, edit(assigns, &Edit.set_disabled(&1, id, not disabled))}
  end

  def handle_event("contain", %{"id" => id, "container" => container}, assigns),
    do: {:noreply, edit(assigns, &Edit.contain(&1, id, if(container != "", do: container)))}

  # A container's title or a comment's text, typed: one undo step per item.
  def handle_event("set_text", values, %{selected: id} = assigns) when is_binary(id),
    do: {:noreply, edit(assigns, &Edit.set_text(&1, id, values["text"] || ""), {:text, id})}

  def handle_event("annotate", values, %{selected: id} = assigns) when is_binary(id) do
    text = values["annotation"] || ""
    assigns = edit(assigns, &Edit.set_annotation(&1, id, text), {:annotation, id})
    {:noreply, %{assigns | drafts: Map.put(assigns.drafts, "_annotation", text)}}
  end

  def handle_event("summarise", _values, %{selected: id} = assigns) when is_binary(id) do
    case Edit.find(assigns.spec, id) do
      %Spec.Node{} = node ->
        assigns = edit(assigns, &Edit.set_annotation(&1, id, Config.summary(node)))
        {:noreply, %{assigns | drafts: Map.delete(assigns.drafts, "_annotation")}}

      _ ->
        {:noreply, assigns}
    end
  end

  # On a phone, choosing a tool shows its properties.
  def handle_event("select", %{"id" => id}, assigns) do
    assigns = select(assigns, id)
    {:noreply, if(phone?(assigns), do: %{assigns | pane: "properties"}, else: assigns)}
  end

  def handle_event("resize", %{"width" => width, "height" => height}, assigns),
    do: {:noreply, %{assigns | width: width, height: height}}

  def handle_event("pane", %{"pane" => pane}, assigns)
      when pane in ["canvas", "properties", "results"],
      do: {:noreply, %{assigns | pane: pane}}

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

  def handle_event("picked", %{"key" => key, "path" => path}, assigns),
    do: {:noreply, configure(assigns, key, path, path)}

  def handle_event("add_formula", _values, assigns),
    do: {:noreply, %{assigns | formula_rows: formula_rows(assigns) + 1}}

  # Drags arrive in screen pixels; at a zoom they move the node by the
  # canvas distance under the pointer.
  def handle_event("move", %{"id" => id, "dx" => dx, "dy" => dy}, %{zoom: zoom} = assigns) do
    {dx, dy} = {round(dx * 100 / zoom), round(dy * 100 / zoom)}
    {:noreply, edit(assigns, &Edit.move(&1, id, dx, dy))}
  end

  def handle_event("pan", %{"dx" => dx, "dy" => dy}, %{zoom: zoom, pan: {px, py}} = assigns) do
    {min_x, min_y} = min_position(assigns.spec)
    # Never so far left or up that the first tool leaves the canvas.
    x = max(px + round(dx * 100 / zoom), -min_x)
    y = max(py + round(dy * 100 / zoom), -min_y)
    {:noreply, %{assigns | pan: {x, y}}}
  end

  # Window shortcuts. Ctrl and Cmd (meta) are both the command key, so the
  # same chords work on Linux, Windows and macOS.
  def handle_event("shortcut", %{"key" => key} = keys, assigns) do
    case {keys["ctrl"] or keys["meta"], String.downcase(key), keys["shift"]} do
      {true, "z", false} ->
        handle_event("undo", %{}, assigns)

      {true, "z", true} ->
        handle_event("redo", %{}, assigns)

      {true, "y", _} ->
        handle_event("redo", %{}, assigns)

      {true, "s", _} ->
        handle_event("save", %{}, assigns)

      {true, "enter", _} ->
        handle_event("run", %{}, assigns)

      {true, zoom_in, _} when zoom_in in ["=", "+"] ->
        handle_event("zoom", %{"by" => "1"}, assigns)

      {true, "-", _} ->
        handle_event("zoom", %{"by" => "-1"}, assigns)

      {true, "0", _} ->
        handle_event("reset_view", %{}, assigns)

      _ ->
        {:noreply, assigns}
    end
  end

  def handle_event("ribbon", %{"tab" => tab}, assigns) do
    {:noreply, %{assigns | tab: tab}}
  end

  def handle_event("zoom", %{"by" => by}, assigns) do
    i = Enum.find_index(@zooms, &(&1 == assigns.zoom)) + String.to_integer(by)
    {:noreply, %{assigns | zoom: Enum.at(@zooms, max(0, min(i, length(@zooms) - 1)))}}
  end

  def handle_event("reset_view", _values, assigns),
    do: {:noreply, %{assigns | zoom: 100, pan: {0, 0}}}

  def handle_event("undo", _values, %{past: [previous | past]} = assigns),
    do:
      {:noreply,
       restore(%{assigns | past: past, future: [assigns.spec | assigns.future]}, previous)}

  def handle_event("undo", _values, assigns), do: {:noreply, assigns}

  def handle_event("redo", _values, %{future: [next | future]} = assigns),
    do:
      {:noreply, restore(%{assigns | future: future, past: [assigns.spec | assigns.past]}, next)}

  def handle_event("redo", _values, assigns), do: {:noreply, assigns}

  # A container goes alone, or with its tools when `tools` is "true".
  def handle_event("remove", %{"id" => id} = values, assigns) do
    assigns = edit(assigns, &Edit.remove(&1, id, with_tools: values["tools"] == "true"))

    {:noreply,
     if(Edit.find(assigns.spec, assigns.selected), do: assigns, else: select(assigns, nil))}
  end

  def handle_event("connect_from", %{"from" => from}, assigns) do
    status = {:info, "Connecting from #{from}", "Choose an input on another node."}
    {:noreply, %{assigns | from: from, status: status}}
  end

  def handle_event("connect_to", %{"id" => id, "port" => port}, %{from: from} = assigns)
      when is_binary(from) do
    if elem(Spec.source(from), 0) == id,
      do: {:noreply, assigns},
      else: {:noreply, edit(assigns, &Edit.connect(&1, from, id, port))}
  end

  def handle_event("show_output", %{"output" => output}, assigns),
    do: {:noreply, %{assigns | output: output}}

  def handle_event("connect_to", _values, assigns) do
    status = {:info, "Choose where the data comes from first.", "Press out on that node."}
    {:noreply, %{assigns | status: status}}
  end

  def handle_event("run", _values, assigns) do
    result =
      with {:ok, spec} <- Spec.validate(assigns.spec),
           {:ok, results} <- IxpipeCore.run(with_home(spec, assigns.dir)) do
        previews = Map.new(results, fn {id, table} -> {id, preview(table)} end)
        {:ok, Map.new(previews, fn {id, p} -> {id, p.total} end), previews}
      end

    case result do
      {:ok, rows, previews} ->
        hint =
          if assigns.selected,
            do: "Results shows #{assigns.selected}.",
            else: "Select a tool to see its rows in Results."

        skipped = Spec.skipped(assigns.spec)

        hint =
          if skipped == [],
            do: hint,
            else: "#{hint} #{plural(length(skipped), "tool")} skipped: disabled, or after one."

        status = {:success, "Run succeeded", hint}

        # On a phone, a selected tool's rows show at once.
        pane = if phone?(assigns) && assigns.selected, do: "results", else: assigns.pane

        {:noreply,
         %{assigns | status: status, rows: rows, previews: previews, pane: pane, skipped: skipped}}

      {:error, {:node_failed, id, message}} ->
        status = {:danger, "#{id} failed.", "#{message} Fix its config and run again."}
        {:noreply, %{assigns | status: status, rows: %{}, previews: %{}, skipped: []}}

      {:error, reason} ->
        status = {:danger, "The workflow can't run yet.", Spec.format_error(reason)}
        {:noreply, %{assigns | status: status, rows: %{}, previews: %{}, skipped: []}}
    end
  end

  def handle_info(:dismiss_toast, assigns), do: {:noreply, %{assigns | toast: nil}}

  defp home(assigns) do
    files =
      for file <- assigns.dir |> File.ls!() |> Enum.sort(),
          String.ends_with?(file, ".yaml"),
          do: {file, modified(Path.join(assigns.dir, file))}

    %{
      assigns
      | files: files,
        spec: nil,
        path: nil,
        from: nil,
        status: nil,
        toast: nil,
        rows: %{},
        skipped: [],
        pane: "canvas"
    }
  end

  defp open(assigns, path) do
    case path |> File.read!() |> Spec.decode() do
      {:ok, spec} ->
        %{
          assigns
          | spec: spec |> place() |> fit_boxes(),
            path: path,
            error: nil,
            status: nil,
            rows: %{},
            skipped: []
        }

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

  # Applies an edit and records the workflow before it for undo. Edits with
  # the same `step` in a row (typing into one setting) are one undo step.
  defp edit(assigns, fun, step \\ nil) do
    spec = assigns.spec |> fun.() |> fit_boxes()

    past =
      cond do
        spec == assigns.spec -> assigns.past
        step != nil and step == assigns.last_step -> assigns.past
        true -> Enum.take([assigns.spec | assigns.past], @history)
      end

    future = if spec == assigns.spec, do: assigns.future, else: []

    %{
      assigns
      | spec: spec,
        past: past,
        future: future,
        last_step: step,
        from: nil,
        status: nil,
        rows: %{},
        previews: %{},
        skipped: []
    }
  end

  # Where something new goes: a step down and right for each thing there.
  defp free_spot(spec) do
    n = length(spec.nodes) + length(spec.containers) + length(spec.comments)
    %{"x" => 40 + 30 * n, "y" => 40 + 30 * n}
  end

  # The first spot, top to bottom and left to right, where a `{width,
  # height}` box clears everything on the canvas; else below it all.
  defp open_space(spec, {w, h}) do
    taken = extents(spec, 100, %{})
    clear? = fn {x, y} -> Enum.all?(taken, &(not overlap?({x, y, w, h}, &1))) end
    bottom = Enum.max(Enum.map(taken, &(elem(&1, 1) + elem(&1, 3))), fn -> 0 end)

    case Enum.find(for(y <- 0..600//20, x <- 0..800//20, do: {x, y}), clear?) do
      {x, y} -> %{"x" => x, "y" => y}
      nil -> %{"x" => 40, "y" => bottom + 24}
    end
  end

  # Two boxes closer than 12px count as overlapping.
  defp overlap?({x1, y1, w1, h1}, {x2, y2, w2, h2}),
    do: x1 < x2 + w2 + 12 and x2 < x1 + w1 + 12 and y1 < y2 + h2 + 12 and y2 < y1 + h1 + 12

  # Where a tool created in container `c` goes: inside an empty one, or to
  # the right of its tools.
  defp inside(spec, c) do
    case Enum.filter(spec.nodes, &(&1.id in c.nodes)) do
      [] ->
        %{"x" => c.position["x"] + @box_pad, "y" => c.position["y"] + @box_bar}

      held ->
        %{
          "x" => Enum.max(Enum.map(held, & &1.position["x"])) + @node_width + 40,
          "y" => Enum.min(Enum.map(held, & &1.position["y"]))
        }
    end
  end

  # A container holding tools is drawn around them, so its saved position
  # follows its box; one too near the canvas's edge for its title bar moves
  # down and right, with its tools, to make room.
  defp fit_boxes(spec) do
    Enum.reduce(spec.containers, spec, fn c, spec ->
      case Enum.filter(spec.nodes, &(&1.id in c.nodes)) do
        [] ->
          spec

        held ->
          x = Enum.min(Enum.map(held, & &1.position["x"])) - @box_pad
          y = Enum.min(Enum.map(held, & &1.position["y"])) - @box_bar
          spec = Edit.move(spec, c.id, max(-x, 0), max(-y, 0))
          at = %{"x" => max(x, 0), "y" => max(y, 0)}

          %{
            spec
            | containers:
                Enum.map(spec.containers, &if(&1.id == c.id, do: %{&1 | position: at}, else: &1))
          }
      end
    end)
  end

  # Tools hidden in collapsed containers.
  defp hidden(spec), do: for(c <- spec.containers, c.collapsed, id <- c.nodes, do: id)

  # Tools drawn disabled: their own, or their container's.
  defp off(spec) do
    for(node <- spec.nodes, node.disabled, do: node.id) ++
      for(c <- spec.containers, c.disabled, id <- c.nodes, do: id)
  end

  # Each container with its box, `{x, y, width, height}` on the canvas.
  defp boxes(spec, zoom, rows),
    do: for(c <- spec.containers, do: {c, box(c, spec.nodes, &card_height(&1, zoom, rows))})

  defp box(c, nodes, height) do
    %{"x" => x, "y" => y} = c.position
    {empty_w, empty_h} = @box_empty

    case Enum.filter(nodes, &(&1.id in c.nodes)) do
      _ when c.collapsed ->
        {x, y, 240, @box_bar}

      [] ->
        {x, y, empty_w, empty_h}

      held ->
        right = Enum.max(Enum.map(held, &(&1.position["x"] + @node_width))) + @box_pad
        bottom = Enum.max(Enum.map(held, &(&1.position["y"] + height.(&1)))) + @box_pad
        {x, y, right - x, bottom - y}
    end
  end

  # A card's height on the canvas, estimated from what it shows (cards grow
  # with their content, and their text does not scale with the zoom): the
  # name and tool, the In and Out rows (two ports a line), output counts
  # after a run, and its annotation.
  defp card_height(node, zoom, rows) do
    outs = Tools.outputs(node.tool)

    ports =
      cond do
        compact?(zoom) -> 0
        node.tool.inputs() == [] -> 37 * div(length(outs) + 1, 2)
        true -> 37 + 37 * div(length(outs) + 1, 2)
      end

    counts = if multi?(node) and rows["#{node.id}.#{hd(outs)}"], do: 23 * length(outs), else: 0
    note = if node.annotation, do: 24, else: 0
    round((if(compact?(zoom), do: 70, else: 90) + ports + counts + note) * 100 / zoom)
  end

  defp box_title(%{title: ""}), do: "Untitled container"
  defp box_title(%{title: title}), do: title

  # Containers and comments: a grey box, teal-bordered when selected.
  defp box_state(id, id), do: "border-primary bg-muted/40"
  defp box_state(_id, _selected), do: "border-border bg-muted/40"

  # Each wire as `{x1, y1, x2, y2}` on the canvas. A wire to or from a tool
  # in a collapsed container ends at the container's edge; one inside it is
  # hidden.
  defp wires(spec, boxes) do
    folded = for {c, b} <- boxes, c.collapsed, id <- c.nodes, into: %{}, do: {id, {c.id, b}}

    # (A match in a comprehension filters, so `from` and `to` come from a
    # generator.)
    for {source, node, out_slot, in_slot} <- edges(spec),
        {from, to} <- [{folded[source.id], folded[node.id]}],
        from == nil or to == nil or elem(from, 0) != elem(to, 0) do
      {x1, y1} =
        case from do
          nil ->
            {source.position["x"] + @node_width, source.position["y"] + @port_y + 12 * out_slot}

          {_, {x, y, w, h}} ->
            {x + w, y + div(h, 2)}
        end

      {x2, y2} =
        case to do
          nil -> {node.position["x"], node.position["y"] + @port_y + 12 * in_slot}
          {_, {x, y, _w, h}} -> {x, y + div(h, 2)}
        end

      {x1, y1, x2, y2}
    end
  end

  # Database tools find saved connections in the workflows folder; it is
  # given for the run only, never saved into the workflow.
  defp with_home(spec, dir),
    do: %{spec | nodes: Enum.map(spec.nodes, &%{&1 | config: Map.put(&1.config, "_home", dir)})}

  defp restore(assigns, spec) do
    selected = if Edit.find(spec, assigns.selected), do: assigns.selected

    %{
      assigns
      | spec: spec,
        last_step: nil,
        from: nil,
        status: nil,
        rows: %{},
        previews: %{},
        skipped: [],
        selected: selected,
        drafts: %{},
        errors: %{}
    }
  end

  defp select(assigns, id),
    do: %{assigns | selected: id, output: nil, drafts: %{}, errors: %{}, formula_rows: 1}

  # Applies a setting typed or chosen in the properties panel. What was typed
  # stays as a draft, so the input never rewrites it; an invalid value shows
  # why and leaves the workflow as it was.
  defp configure(assigns, key, text, draft) do
    drafts = if draft, do: Map.put(assigns.drafts, key, draft), else: assigns.drafts

    case Edit.set_config(assigns.spec, assigns.selected, key, text) do
      {:ok, spec} ->
        assigns = edit(assigns, fn _ -> spec end, {:config, assigns.selected, key})
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

  # The first rows of a tool's output, as strings, for the results grid, and
  # its row count: all the view keeps, so a run's tables can be dropped.
  defp preview(table) do
    {columns, rows} = Table.values(table, @preview_rows)
    rows = Enum.map(rows, &Enum.map(&1, fn v -> cell(v) end))
    numeric = for {name, type} <- Table.dtypes(table), numeric?(type), do: name
    %{columns: columns, rows: rows, total: Table.count(table), numeric: numeric}
  end

  @numeric ~w(TINYINT SMALLINT INTEGER BIGINT HUGEINT UTINYINT USMALLINT UINTEGER UBIGINT
              UHUGEINT FLOAT DOUBLE)
  defp numeric?(type), do: type in @numeric or String.starts_with?(type, "DECIMAL")

  defp cell(nil), do: "—"
  defp cell(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp cell(value) when is_map(value) and not is_struct(value), do: Jason.encode!(value)
  defp cell(value) when is_list(value), do: Jason.encode!(value)
  defp cell(value), do: to_string(value)

  # Each edge with the slot of the output it leaves and of the input it
  # enters, so a filter's true and false wires, and a join's left and right
  # inputs, sit one above the other.
  defp edges(spec) do
    by_id = Map.new(spec.nodes, &{&1.id, &1})

    for node <- spec.nodes,
        {port, in_slot} <- Enum.with_index(node.tool.inputs()),
        ref = node.inputs[port],
        {from, output} = Spec.source(ref || ""),
        source = by_id[from],
        outputs = Tools.outputs(source.tool),
        do: {source, node, Enum.find_index(outputs, &(&1 == output)) || 0, in_slot}
  end

  defp multi?(node), do: length(Tools.outputs(node.tool)) > 1

  # A connector per output: `{label, wire source, accessible name}`.
  defp connectors(node) do
    case Tools.outputs(node.tool) do
      [_] -> [{"out", node.id, "Connect from #{node.id}"}]
      outs -> for out <- outs, do: {out, "#{node.id}.#{out}", "Connect from #{node.id} #{out}"}
    end
  end

  # The run result Results shows for `node`: its own, or the chosen output.
  defp output_key(node, chosen) do
    case Tools.outputs(node.tool) do
      [_] -> node.id
      [first | _] = outs -> "#{node.id}.#{if chosen in outs, do: chosen, else: first}"
    end
  end

  # The surface covers the furthest tool, container or comment at the
  # current zoom and pan.
  defp surface(spec, zoom, {px, py}) do
    {w, h} =
      Enum.reduce(extents(spec, zoom, %{}), {0, 0}, fn {x, y, width, height}, {w, h} ->
        {max(w, x + px + width + 40), max(h, y + py + height + 10)}
      end)

    "w-[#{scaled(w, zoom)}px] h-[#{scaled(h, zoom)}px]"
  end

  # Everything on the canvas as `{x, y, width, height}`.
  defp extents(spec, zoom, rows) do
    for(
      %{position: %{"x" => x, "y" => y}} = node <- spec.nodes,
      do: {x, y, @node_width, card_height(node, zoom, rows)}
    ) ++
      for({_c, box} <- boxes(spec, zoom, rows), do: box) ++
      for(
        %{position: %{"x" => x, "y" => y}} = c <- spec.comments,
        do: {x, y, @comment_width, comment_height(c)}
      )
  end

  # About 28 characters a line under the comment's icon.
  defp comment_height(c), do: 48 + 20 * max(div(String.length(c.text) + 27, 28), 1)

  defp min_position(spec) do
    case extents(spec, 100, %{}) do
      [] -> {0, 0}
      all -> {Enum.min(Enum.map(all, &elem(&1, 0))), Enum.min(Enum.map(all, &elem(&1, 1)))}
    end
  end

  # Where a tool shows: its canvas position, panned, at the zoom.
  defp vx(node, zoom, {px, _}), do: scaled(node.position["x"] + px, zoom)
  defp vy(node, zoom, {_, py}), do: scaled(node.position["y"] + py, zoom)
  defp scaled(length, zoom), do: round(length * zoom / 100)
  # A canvas coordinate on screen: `axis` 0 is x, 1 is y.
  defp at(value, pan, axis, zoom), do: scaled(value + elem(pan, axis), zoom)
  defp compact?(zoom), do: zoom < 100
  defp zooms, do: @zooms

  defp card_state(id, selected, from) do
    cond do
      from && elem(Spec.source(from), 0) == id -> "border-primary bg-primary/12"
      selected == id -> "border-primary bg-background"
      true -> "border-border bg-background"
    end
  end

  ## Panels

  attr(:toast, :string, default: nil)
  attr(:status, :any, default: nil)
  attr(:phone, :boolean, required: true)

  # The toast and the status callout, over the canvas (on a phone, over
  # whichever pane shows), so feedback never moves the layout; the opaque
  # backing keeps the callout's tint from showing the canvas through.
  defp feedback(assigns) do
    ~H"""
    <.toast :if={@toast} message={@toast} />
    <div :if={@status} class={"absolute rounded-md bg-background shadow-md " <>
      if(@phone, do: "left-[12px] right-[12px] bottom-[12px]", else: "left-[16px] bottom-[16px] w-[420px]")}>
      <.callout tone={elem(@status, 0)} title={elem(@status, 1)}>{elem(@status, 2)}</.callout>
    </div>
    """
  end

  attr(:node, :map, default: nil)
  attr(:preview, :map, default: nil)
  attr(:output, :string, default: nil)
  attr(:skipped, :boolean, default: false)
  attr(:phone, :boolean, default: false)

  defp results(assigns) do
    ~H"""
    <section class={"flex-col gap-2 p-4 " <> if(@phone, do: "flex-1", else: "h-[240px]")} aria-label="Results">
      <div class="flex-row items-center gap-2">
        <.section>Results</.section>
        <.caption :if={@preview}>{@output} · {plural(@preview.total, "row")}{if @preview.total > length(@preview.rows), do: ", first #{length(@preview.rows)} shown"}</.caption>
      </div>
      <div :if={@node && multi?(@node)} class="flex-row gap-1">
        <.button :for={out <- Tools.outputs(@node.tool)} size={touch(@phone, :sm)} phx-click="show_output"
          phx-value-output={out} aria-label={"Show #{out} output"}
          class={if @output == "#{@node.id}.#{out}", do: "border-primary bg-primary/12", else: ""}>
          {out}
        </.button>
      </div>
      <.caption :if={!@node}>Select a tool to see its results.</.caption>
      <.caption :if={@node && !@preview && @skipped}>
        This tool was skipped: it is disabled, or follows a disabled tool. Enable it and run again.
      </.caption>
      <.caption :if={@node && !@preview && !@skipped}>Run the workflow to see this tool's results.</.caption>
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
  attr(:item, :map, default: nil)
  attr(:drafts, :map, required: true)
  attr(:errors, :map, required: true)
  attr(:formula_rows, :integer, required: true)
  attr(:dir, :string, required: true)
  attr(:phone, :boolean, default: false)
  attr(:containers, :list, default: [])
  attr(:off, :list, default: [])

  defp properties(assigns) do
    ~H"""
    <aside class={"flex-col gap-6 p-4 overflow-y-scroll " <> if(@phone, do: "flex-1 w-full", else: "w-[320px]")}
      aria-label="Configuration">
      <.empty_state :if={!@item} title="Nothing selected">Select a tool to configure it.</.empty_state>
      <.container_properties :if={match?(%Spec.Container{}, @item)} container={@item} size={touch(@phone, :sm)} />
      <.comment_properties :if={match?(%Spec.Comment{}, @item)} comment={@item} size={touch(@phone, :sm)} />
      <div :if={@node} class="flex-col gap-1">
        <.section>{@node.id}</.section>
        <.caption>{tool_label(Tools.name(@node.tool))}</.caption>
      </div>
      <.organise :if={@node} node={@node} containers={@containers} off={@off} drafts={@drafts}
        size={touch(@phone, :sm)} />
      <.caption :if={@node && @node.tool.fields() == []}>This tool has no settings.</.caption>
      <form :if={@node} phx-change="config" aria-label="Settings" class="flex-col gap-3">
        <.field :for={field <- @node.tool.fields()} field={field} node={@node} drafts={@drafts}
          error={@errors[field.key]} formula_rows={@formula_rows} dir={@dir} size={touch(@phone, :sm)} />
      </form>
    </aside>
    """
  end

  attr(:container, :map, required: true)
  attr(:size, :atom, default: :sm)

  defp container_properties(assigns) do
    ~H"""
    <div class="flex-col gap-1">
      <.section>{box_title(@container)}</.section>
      <.caption>Container · {plural(length(@container.nodes), "tool")}</.caption>
    </div>
    <div class="flex-col gap-1">
      <.label>Title</.label>
      <input name="text" value={@container.title} phx-change="set_text" aria-label="Title" class="w-full" />
    </div>
    <div class="flex-row flex-wrap gap-1">
      <.button size={@size} phx-click="collapse" phx-value-id={@container.id}
        icon={if @container.collapsed, do: "chevron-right", else: "chevron-down"}
        aria-label={if @container.collapsed, do: "Expand container", else: "Collapse container"}>
        {if @container.collapsed, do: "Expand container", else: "Collapse container"}
      </.button>
      <.button size={@size} phx-click="disable" phx-value-id={@container.id}
        icon={if @container.disabled, do: "circle-check", else: "circle-off"}
        aria-label={if @container.disabled, do: "Enable container", else: "Disable container"}>
        {if @container.disabled, do: "Enable container", else: "Disable container"}
      </.button>
    </div>
    <.caption>
      A disabled container's tools, and everything after them, are skipped when the workflow runs.
    </.caption>
    <div class="flex-row flex-wrap gap-1">
      <.button variant={:danger} size={@size} phx-click="remove" phx-value-id={@container.id}
        aria-label="Remove container">Remove container</.button>
      <.button variant={:danger} size={@size} phx-click="remove" phx-value-id={@container.id} phx-value-tools="true"
        aria-label="Remove container and tools">Remove container and tools</.button>
    </div>
    """
  end

  attr(:comment, :map, required: true)
  attr(:size, :atom, default: :sm)

  defp comment_properties(assigns) do
    ~H"""
    <.section>Comment</.section>
    <div class="flex-col gap-1">
      <.label>Text</.label>
      <input name="text" value={@comment.text} phx-change="set_text" aria-label="Comment"
        placeholder="A note on the canvas" class="w-full" />
    </div>
    <div class="flex-row">
      <.button variant={:danger} size={@size} phx-click="remove" phx-value-id={@comment.id}
        aria-label="Remove comment">Remove comment</.button>
    </div>
    """
  end

  attr(:node, :map, required: true)
  attr(:containers, :list, required: true)
  attr(:off, :list, required: true)
  attr(:drafts, :map, required: true)
  attr(:size, :atom, default: :sm)

  # A tool's place on the canvas: enabled or not, its container, its annotation.
  defp organise(assigns) do
    assigns =
      assign(assigns, :holder, Enum.find(assigns.containers, &(assigns.node.id in &1.nodes)))

    ~H"""
    <div class="flex-col gap-3">
      <div class="flex-col gap-1">
        <div class="flex-row">
          <.button size={@size} phx-click="disable" phx-value-id={@node.id}
            icon={if @node.disabled, do: "circle-check", else: "circle-off"}
            aria-label={if @node.disabled, do: "Enable tool", else: "Disable tool"}>
            {if @node.disabled, do: "Enable tool", else: "Disable tool"}
          </.button>
        </div>
        <.caption :if={@node.disabled}>A run skips it, with every tool after it.</.caption>
        <.caption :if={!@node.disabled && @node.id in @off}>Disabled by its container.</.caption>
      </div>
      <div :if={@containers != []} class="flex-col gap-1">
        <.label>Container</.label>
        <div class="flex-row flex-wrap gap-1">
          <.button :for={c <- @containers} size={@size} phx-click="contain" phx-value-id={@node.id}
            phx-value-container={c.id} aria-label={"Put in #{box_title(c)}"}
            class={if @holder == c, do: "border-primary bg-primary/12", else: ""}>{box_title(c)}</.button>
          <.button :if={@holder} size={@size} phx-click="contain" phx-value-id={@node.id} phx-value-container=""
            aria-label="Take out of container">None</.button>
        </div>
      </div>
      <div class="flex-col gap-1">
        <div class="flex-row items-center gap-2">
          <.label>Annotation</.label>
          <.caption>Optional</.caption>
        </div>
        <input name="annotation" value={@drafts["_annotation"] || @node.annotation || ""} phx-change="annotate"
          aria-label="Annotation" placeholder="Shown under the tool" class="w-full" />
        <div class="flex-row">
          <.button size={@size} phx-click="summarise" icon="scroll-text" aria-label="Summarise settings">
            Summarise settings
          </.button>
        </div>
      </div>
    </div>
    """
  end

  attr(:field, :map, required: true)
  attr(:node, :map, required: true)
  attr(:drafts, :map, required: true)
  attr(:error, :string, default: nil)
  attr(:formula_rows, :integer, required: true)
  attr(:dir, :string, default: nil)
  attr(:size, :atom, default: :sm)

  # A database tool's saved connection: the saved connections of its kind,
  # as choices, from connections.yaml in the workflows folder.
  defp field(%{field: %{key: "connection"}} = assigns) do
    kind = if Tools.name(assigns.node.tool) =~ "postgres", do: "postgres", else: "sqlite"
    names = for %{"type" => ^kind, "name" => name} <- Connections.list(assigns.dir), do: name
    assigns = Map.merge(assigns, %{names: names, kind: kind})

    ~H"""
    <div class="flex-col gap-1">
      <div class="flex-row items-center gap-2">
        <.label>{@field.label}</.label>
        <.caption :if={@field[:optional]}>Optional</.caption>
      </div>
      <div :if={@names != []} class="flex-row flex-wrap gap-1">
        <.button :for={name <- @names} size={@size} phx-click="choose" phx-value-key="connection"
          phx-value-value={name} aria-label={"Connection #{name}"}
          class={if @node.config["connection"] == name, do: "border-primary bg-primary/12", else: ""}>
          {name}
        </.button>
      </div>
      <.caption :if={@names == []}>
        No saved connections yet. Add a {@kind} connection to connections.yaml in {@dir}.
      </.caption>
      <.caption :if={@error} class="text-danger">{@error}</.caption>
    </div>
    """
  end

  defp field(%{field: %{type: :bool}} = assigns) do
    ~H"""
    <div class="flex-row items-center gap-2">
      <input type="checkbox" checked={Map.get(@node.config, @field.key, @field[:default]) == true}
        phx-click="switch"
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
        <.button :for={option <- @field.options} size={@size} phx-click="choose" phx-value-key={@field.key}
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
        <.button size={@size} phx-click="add_formula" aria-label="Add a formula">Add a formula</.button>
      </div>
    </div>
    """
  end

  defp field(%{field: %{type: :path}} = assigns) do
    ~H"""
    <div class="flex-col gap-1">
      <.label>{@field.label}</.label>
      <div class="flex-row items-center gap-2">
        <div class="flex-1">
          <input name={@field.key} value={@drafts[@field.key] || Config.format(@field, @node.config[@field.key])}
            aria-label={@field.label} class="w-full" />
        </div>
        <.button :if={!@field[:save]} size={@size} phx-pick-file="picked" phx-value-key={@field.key}
          accept={Enum.join(@field[:accept] || [], ",")} aria-label={"Choose #{String.downcase(@field.label)}"}>
          Choose…
        </.button>
        <.button :if={@field[:save]} size={@size} phx-pick-save="picked" phx-value-key={@field.key}
          accept={Enum.join(@field[:accept] || [], ",")} default-name={"#{@node.id}.#{hd(@field[:accept] || ["csv"])}"}
          aria-label={"Choose #{String.downcase(@field.label)}"}>
          Choose…
        </.button>
      </div>
      <.caption :if={@error} class="text-danger">{@error}</.caption>
      <.caption :if={!@error && @field[:hint]}>{@field.hint}</.caption>
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
        aria-label={@field.label} class="w-full" />
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

  @labels %{
    "input_csv" => "Input CSV",
    "output_csv" => "Output CSV",
    "input_excel" => "Input Excel",
    "output_excel" => "Output Excel",
    "input_parquet" => "Input Parquet",
    "output_parquet" => "Output Parquet",
    "input_sqlite" => "Input SQLite",
    "output_sqlite" => "Output SQLite",
    "cross_tab" => "Cross tab",
    "text_to_columns" => "Text to columns",
    "regex" => "RegEx",
    "data_cleansing" => "Data cleansing",
    "input_postgres" => "Input Postgres"
  }
  defp tool_label(tool), do: Map.get_lazy(@labels, tool, fn -> String.capitalize(tool) end)

  # Lucide icons for the tool commands, as ixtable's ribbon has: an input and
  # an output share their format's icon.
  @icons %{
    "csv" => "file-text",
    "excel" => "file-spreadsheet",
    "parquet" => "file-box",
    "sqlite" => "database",
    "postgres" => "server",
    "select" => "list-checks",
    "formula" => "square-function",
    "data_cleansing" => "sparkles",
    "filter" => "funnel",
    "sort" => "arrow-up-down",
    "sample" => "dices",
    "unique" => "list-x",
    "join" => "merge",
    "union" => "layers",
    "text_to_columns" => "columns-3",
    "regex" => "regex",
    "summarize" => "sigma",
    "cross_tab" => "table-2",
    "transpose" => "arrow-left-right"
  }
  defp tool_icon(tool), do: Map.get(@icons, String.replace(tool, ~r/^(in|out)put_/, ""))

  # A shortcut as the platform writes it: Cmd on macOS, Ctrl elsewhere.
  defp shortcut(key),
    do: if(Baguette.platform() == :macos, do: "Cmd+", else: "Ctrl+") <> key

  defp ribbon_tabs, do: for({key, label, _} <- @ribbon, do: {key, label})

  defp ribbon_groups(tab),
    do: Enum.find_value(@ribbon, [], fn {key, _, groups} -> key == tab && groups end)

  # In the Input and Output groups the group names the direction: "CSV".
  defp command_label(group, tool),
    do: tool |> tool_label() |> String.replace_prefix(group <> " ", "")

  defp phone?(%{width: width}), do: is_integer(width) and width < @phone_width
  defp panes, do: @panes

  # The phone's touch size (40px), or `size` on a wider window.
  defp touch(phone, size \\ :md)
  defp touch(true, _size), do: :touch
  defp touch(false, size), do: size

  defp node_width, do: @node_width
  defp comment_width, do: @comment_width
end
