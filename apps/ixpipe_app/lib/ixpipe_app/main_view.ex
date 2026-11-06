defmodule IxpipeApp.MainView do
  @moduledoc """
  The main window: a home screen listing the workflows in a directory, and a
  canvas to build, wire, save and run one. Built from `IxpipeApp.Components`
  to the design language in AGENTS.md.

  Args: `:dir` (the workflows directory) and, optionally, `:path` to open.
  """
  use Baguette.View
  import IxpipeApp.Components

  alias IxpipeCore.{
    Config,
    Connections,
    Edit,
    Functions,
    Macro,
    Profile,
    Script,
    Spec,
    Table,
    Tools
  }

  alias IxpipeCore.Tools.Select

  @node_width 200
  # Room a new card needs: a tool with its In and Out rows.
  @new_card_height 170
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
  @page_rows 50
  @browse %{page: 0, sort: nil, view: "data"}
  # Narrower than this (a phone in portrait), the window shows one pane at
  # a time: Canvas, Properties, Results or Messages.
  @phone_width 640
  @fn_categories ["all" | IxpipeCore.Functions.categories()]
  @panes [
    {"canvas", "Canvas"},
    {"properties", "Properties"},
    {"results", "Results"},
    {"messages", "Messages"}
  ]
  # Under the canvas on a wider window: the selected tool's rows, or the
  # last run's messages.
  @panels [{"results", "Results"}, {"messages", "Messages"}]
  # Messages' filters: `{key, label, accessible name}`.
  @levels [
    {"all", "All", "Show all messages"},
    {"error", "Errors", "Show errors"},
    {"warning", "Warnings", "Show warnings"},
    {"info", "Info", "Show info"}
  ]
  # The ribbon's tabs: Home edits and views the workflow; the rest hold the
  # tools, by category, in labelled groups. A group of rows (In/Out's files
  # over databases) stacks them on a desktop and runs them on in one row,
  # scrolling sideways, on a phone.
  @ribbon [
    {"home", "Home", []},
    {"inout", "In/Out",
     [
       {"Input",
        [
          ~w(input_csv input_excel input_parquet input_json),
          ~w(input_sqlite input_postgres input_mysql input_sqlserver input_bigquery)
        ]},
       {"Output",
        [
          ~w(output_csv output_excel output_parquet output_json),
          ~w(output_sqlite output_postgres output_mysql output_sqlserver)
        ]}
     ]},
    {"prepare", "Preparation",
     [
       {"Columns", ~w(select data_cleansing auto_field imputation)},
       {"Formula", ~w(formula multi_row_formula multi_field_formula)},
       {"Rows", ~w(filter sort sample unique)}
     ]},
    {"join", "Join",
     [
       {"Combine", ~w(join union join_multiple append_fields)},
       {"Match", ~w(find_replace fuzzy_match)}
     ]},
    {"parse", "Parse", [{"Split", ~w(text_to_columns regex)}, {"Convert", ~w(date_time)}]},
    {"transform", "Transform",
     [
       {"Aggregate", ~w(summarize running_total)},
       {"Sequence", ~w(record_id tile generate_rows)},
       {"Reshape", ~w(cross_tab transpose)}
     ]},
    {"code", "Code", [{"Code", ~w(python script)}]},
    # Macro tools are added here; a macro itself is used with "Use a macro…".
    {"macros", "Macros", [{"Macros", ~w(macro_input macro_output)}]}
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
      # The last run's tables, alive in its DuckDB database while Results
      # browses them; an edit drops them.
      results: %{},
      # The last run's columns of every output, kept across edits so
      # Select's editor can list its input's columns.
      schemas: %{},
      # Results: the page, sort and view (data or profile), and what they show.
      browse: @browse,
      grid: nil,
      profile: nil,
      # The Select row whose type picker is open.
      type_open: nil,
      selected: nil,
      output: nil,
      drafts: %{},
      errors: %{},
      formula_rows: 1,
      # The function reference's search and category, and the expression
      # being typed: where inserts and completions go.
      fn_query: "",
      fn_category: nil,
      typing: nil,
      code_rows: 1,
      # On a phone (Android, iOS), Script can't start other programs.
      mobile: Keyword.get_lazy(args, :mobile, &Baguette.mobile?/0),
      past: [],
      future: [],
      last_step: nil,
      zoom: 100,
      pan: {0, 0},
      tab: "home",
      width: nil,
      height: nil,
      pane: "canvas",
      panel: "results",
      level: "all",
      run: nil,
      # The workflows a macro was opened from, the nearest first, each as it
      # was left: `%{path, spec, past, future, selected}`.
      trail: []
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
        <li :for={{file, modified, macro} <- @files} class="flex-row items-center justify-between gap-3">
          <div class="flex-row items-center gap-2">
            <.button variant={:quiet} size={touch(@phone)} phx-click="open" phx-value-file={file} aria-label={"Open #{file}"}>
              {file}
            </.button>
            <div :if={macro} aria-label={"#{file} is a macro"}><.status_badge>Macro</.status_badge></div>
          </div>
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
          <.breadcrumb crumbs={crumbs(@trail, @path)} touch={@phone} />
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
            <div class="flex-col gap-1">
              <div :for={row <- ribbon_rows(tools, @phone)} data-row="true" class="flex-row items-center gap-1">
                <.button :for={tool <- row} size={touch(@phone, :sm)} variant={:quiet} phx-click="add" phx-value-tool={tool}
                  icon={tool_icon(tool)} aria-label={"Add #{tool}"}>{command_label(group, tool)}</.button>
              </div>
            </div>
            <.button :if={group == "Macros"} size={touch(@phone, :sm)} variant={:quiet} phx-pick-file="use_macro"
              accept="yaml" icon="package" aria-label="Use a macro">Use a macro…</.button>
          </.ribbon_group>
        <% end %>
      </.ribbon>
      <%!-- min-h-0: a long properties panel scrolls instead of pushing Results off the window. --%>
      <div class={"relative flex-1 min-h-0 " <> if(@phone, do: "flex-col", else: "flex-row")}>
        <div :if={!@phone || @pane == "canvas"} class="flex-col flex-1 min-w-0">
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
            <div class="flex-row flex-wrap items-center gap-2">
              <.caption>{node_label(node)}</.caption>
              <.status_badge :if={@rows[node.id]} tone={:success}>{plural(@rows[node.id], "row")}</.status_badge>
              <.run_badge run={@run} id={node.id} />
            </div>
            <div :if={multi?(node)} class="flex-row flex-wrap gap-1">
              <.status_badge :for={out <- Tools.outputs(node)} :if={@rows["#{node.id}.#{out}"]}
                tone={:success}>{out} · {plural(@rows["#{node.id}.#{out}"], "row")}</.status_badge>
            </div>
            <%!-- Inputs and outputs on their own labelled rows: a join's left and
              right inputs are not its left and right outputs. --%>
            <div :if={!compact?(@zoom) && Tools.inputs(node) != []} class="flex-row flex-wrap items-center gap-1">
              <.caption class="w-[28px]">In</.caption>
              <.button :for={port <- Tools.inputs(node)} size={:sm} phx-click="connect_to"
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
        <.results :if={!@phone && @panel == "results"} node={@node} output={@node && output_key(@node, @output)}
          total={@node && @rows[output_key(@node, @output)]} grid={@grid} profile={@profile} browse={@browse}
          skip={skip_reason(@run, @node)} failure={failure(@run, @node)} />
        <.messages :if={!@phone && @panel == "messages"} run={@run} level={@level} spec={@spec} />
        </div>
        <.results :if={@phone && @pane == "results"} node={@node} output={@node && output_key(@node, @output)}
          total={@node && @rows[output_key(@node, @output)]} grid={@grid} profile={@profile} browse={@browse}
          skip={skip_reason(@run, @node)} failure={failure(@run, @node)} phone />
        <.messages :if={@phone && @pane == "messages"} run={@run} level={@level} spec={@spec} phone />
        <div :if={!@phone} class="w-px h-full bg-border" />
        <.properties :if={!@phone || @pane == "properties"} node={@node} item={@item} drafts={@drafts} errors={@errors}
          formula_rows={@formula_rows} code_rows={@code_rows} mobile={@mobile} dir={@dir} phone={@phone} containers={@spec.containers} off={@off}
          schema={@node && input_schema(@spec, @node, @schemas)} type_open={@type_open}
          typing={@typing} fn_query={@fn_query} fn_category={@fn_category} />
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

  # A breadcrumb back to a workflow a macro was opened from, as it was left.
  def handle_event("return_" <> level, _values, assigns) do
    [parent | rest] = Enum.drop(assigns.trail, String.to_integer(level))

    assigns = %{
      restore(assigns, parent.spec)
      | path: parent.path,
        past: parent.past,
        future: parent.future,
        trail: rest
    }

    {:noreply, select(assigns, parent.selected)}
  end

  # Opens the selected macro's workflow, keeping this one to come back to.
  def handle_event("open_macro", _values, assigns) do
    case Enum.find(assigns.spec.nodes, &(&1.id == assigns.selected)) do
      %{macro: %Macro{path: path}} ->
        here = Map.take(assigns, [:path, :spec, :past, :future, :selected])
        trail = [here | assigns.trail]

        case open(assigns, path) do
          %{spec: nil} = home -> {:noreply, home}
          opened -> {:noreply, select(%{opened | trail: trail, past: [], future: []}, nil)}
        end

      _ ->
        {:noreply, assigns}
    end
  end

  # Adds a node for the macro picked, its path relative to this workflow.
  def handle_event("use_macro", %{"path" => path}, assigns) do
    at = %{
      "x" => 40 + 30 * length(assigns.spec.nodes),
      "y" => 40 + 30 * length(assigns.spec.nodes)
    }

    dir = Path.dirname(assigns.path)

    assigns =
      edit(assigns, fn spec ->
        spec = Edit.add_node(spec, "macro", at)
        id = List.last(spec.nodes).id
        {:ok, spec} = Edit.set_config(spec, id, "path", Path.relative_to(path, dir))
        Macro.attach(spec, dir, [Path.expand(assigns.path)])
      end)

    {:noreply, select(assigns, List.last(assigns.spec.nodes).id)}
  end

  def handle_event("save", _values, assigns) do
    File.write!(assigns.path, Spec.to_yaml(assigns.spec))
    Process.send_after(self(), :dismiss_toast, @toast_ms)
    {:noreply, %{assigns | toast: "Saved #{Path.basename(assigns.path)}"}}
  end

  # With a container selected, the new tool goes inside it; otherwise in the
  # first open space, never on top of another card (where clicks on its
  # connectors would land on that card).
  def handle_event("add", %{"tool" => tool}, assigns) do
    {at, container} =
      case Edit.find(assigns.spec, assigns.selected) do
        %Spec.Container{} = c -> {inside(assigns.spec, c), c.id}
        _ -> {new_spot(assigns), nil}
      end

    assigns = edit(assigns, &Edit.add_node(&1, tool, at, container))
    id = List.last(assigns.spec.nodes).id
    {:noreply, assigns |> reveal(id) |> select(id)}
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
      when pane in ["canvas", "properties", "results", "messages"],
      do: {:noreply, %{assigns | pane: pane}}

  def handle_event("panel", %{"tab" => panel}, assigns) when panel in ["results", "messages"],
    do: {:noreply, %{assigns | panel: panel}}

  def handle_event("level", %{"level" => level}, assigns)
      when level in ["all", "error", "warning", "info"],
      do: {:noreply, %{assigns | level: level}}

  # Text settings: the form sends every value with the one that changed as
  # _target. Formula rows are one setting, a line each.
  def handle_event("config", %{"_target" => "formula_" <> _} = values, assigns) do
    rows =
      for {"formula_" <> n, text} <- values, do: {String.to_integer(n), text}

    "formula_" <> n = values["_target"]
    rows = rows |> Enum.sort() |> Enum.map(&elem(&1, 1))
    assigns = %{assigns | typing: {"formulas", String.to_integer(n)}}
    {:noreply, configure(assigns, "formulas", formulas_text(rows), rows)}
  end

  # Select's editor: a row's name, or a type typed rather than chosen.
  def handle_event("config", %{"_target" => "select_name_" <> i = key} = values, assigns) do
    text = values[key] || ""
    i = String.to_integer(i)
    assigns = %{assigns | drafts: Map.put(assigns.drafts, key, text)}
    {:noreply, edit_select(assigns, &Select.edit(&1, &2, i, %{"rename" => text}), key)}
  end

  def handle_event("config", %{"_target" => "select_type_" <> i = key} = values, assigns) do
    text = String.trim(values[key] || "")
    assigns = %{assigns | drafts: Map.put(assigns.drafts, key, text)}

    cond do
      text == "" ->
        {:noreply, %{assigns | errors: Map.delete(assigns.errors, key)}}

      Select.type?(text) ->
        assigns = %{assigns | errors: Map.delete(assigns.errors, key)}
        i = String.to_integer(i)
        {:noreply, edit_select(assigns, &Select.edit(&1, &2, i, %{"type" => text}), key)}

      true ->
        message =
          "#{text} is not a type. Use one of #{Enum.join(Select.common_types(), ", ")}."

        {:noreply, %{assigns | errors: Map.put(assigns.errors, key, message)}}
    end
  end

  # Code is a row per line; a pasted block of lines becomes as many rows.
  def handle_event("config", %{"_target" => "code_line_" <> _} = values, assigns) do
    rows = for {"code_line_" <> n, text} <- values, do: {String.to_integer(n), text}
    text = rows |> Enum.sort() |> Enum.map_join("\n", &elem(&1, 1))
    {:noreply, configure(assigns, "code", text, String.split(text, "\n"))}
  end

  def handle_event("config", %{"_target" => key} = values, assigns) do
    text = values[key] || ""
    {:noreply, configure(%{assigns | typing: key}, key, text, text)}
  end

  def handle_event("search_functions", values, assigns),
    do: {:noreply, %{assigns | fn_query: values["query"] || ""}}

  def handle_event("function_category", %{"category" => category}, assigns)
      when category in @fn_categories,
      do: {:noreply, %{assigns | fn_category: if(category != "all", do: category)}}

  # Clicking a function in the reference adds its signature to the
  # expression being typed; a completion replaces the word being typed with
  # the function's name and an opening bracket.
  def handle_event("insert_function", %{"name" => name}, assigns) do
    case Enum.find(Functions.all(), &(&1.name == name)) do
      nil -> {:noreply, assigns}
      f -> {:noreply, insert(assigns, f.signature, :append)}
    end
  end

  def handle_event("complete_function", %{"name" => name}, assigns) do
    case Enum.find(Functions.all(), &(&1.name == name)) do
      nil ->
        {:noreply, assigns}

      f ->
        text =
          if String.starts_with?(f.signature, f.name <> "("), do: f.name <> "(", else: f.signature

        {:noreply, insert(assigns, text, :complete)}
    end
  end

  def handle_event("choose", %{"key" => key, "value" => value}, assigns),
    do: {:noreply, configure(assigns, key, value, nil)}

  def handle_event("switch", %{"key" => key, "checked" => checked}, assigns),
    do: {:noreply, configure(assigns, key, to_string(checked), nil)}

  def handle_event("picked", %{"key" => key, "path" => path}, assigns),
    do: {:noreply, configure(assigns, key, path, path)}

  def handle_event("select_keep", %{"index" => i, "checked" => checked}, assigns) do
    i = String.to_integer(i)
    {:noreply, edit_select(assigns, &Select.edit(&1, &2, i, %{"keep" => checked == true}))}
  end

  def handle_event("select_move", %{"index" => i, "by" => by}, assigns) do
    {i, by} = {String.to_integer(i), String.to_integer(by)}
    assigns = %{assigns | drafts: %{}, errors: %{}, type_open: nil}
    {:noreply, edit_select(assigns, &Select.move(&1, &2, i, by))}
  end

  def handle_event("select_type_open", %{"index" => i}, assigns) do
    i = String.to_integer(i)
    {:noreply, %{assigns | type_open: if(assigns.type_open == i, do: nil, else: i)}}
  end

  def handle_event("select_type", %{"index" => i, "type" => type}, assigns) do
    i = String.to_integer(i)
    assigns = %{assigns | type_open: nil, drafts: Map.delete(assigns.drafts, "select_type_#{i}")}
    {:noreply, edit_select(assigns, &Select.edit(&1, &2, i, %{"type" => type}))}
  end

  # Results: pages, sorting by a column header (ascending, descending, off)
  # and the data or profile view.
  def handle_event("page", %{"by" => by}, %{browse: browse} = assigns) do
    page = max(browse.page + String.to_integer(by), 0)
    {:noreply, refresh(%{assigns | browse: %{browse | page: page}})}
  end

  def handle_event("sort", %{"column" => column}, %{browse: browse} = assigns) do
    sort =
      case browse.sort do
        {^column, :asc} -> {column, :desc}
        {^column, :desc} -> nil
        _ -> {column, :asc}
      end

    {:noreply, refresh(%{assigns | browse: %{browse | sort: sort, page: 0}})}
  end

  def handle_event("browse_view", %{"view" => view}, %{browse: browse} = assigns)
      when view in ["data", "profile"],
      do: {:noreply, refresh(%{assigns | browse: %{browse | view: view}})}

  def handle_event("add_formula", _values, assigns),
    do: {:noreply, %{assigns | formula_rows: formula_rows(assigns) + 1}}

  def handle_event("add_line", _values, assigns) do
    node = Enum.find(assigns.spec.nodes, &(&1.id == assigns.selected))
    count = max(length(code_lines(node, assigns.drafts)), assigns.code_rows)
    {:noreply, %{assigns | code_rows: count + 1}}
  end

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
    do: {:noreply, refresh(%{assigns | output: output, browse: @browse})}

  def handle_event("connect_to", _values, assigns) do
    status = {:info, "Choose where the data comes from first.", "Press out on that node."}
    {:noreply, %{assigns | status: status}}
  end

  # Every tool that can run does: a failure skips only what is downstream
  # of it, and the tools that ran keep their results.
  def handle_event("run", _values, assigns) do
    case Spec.validate(assigns.spec) do
      {:ok, spec} ->
        # The run's tables stay alive in its database while Results browses
        # them, a partial run's too: only the tools that ran have tables.
        run = IxpipeCore.execute(with_home(spec, assigns.dir))
        rows = Map.new(run.tables, fn {id, table} -> {id, Table.count(table)} end)
        schemas = Map.new(run.tables, fn {id, table} -> {id, Table.schema(table)} end)

        # Results shows a tool's rows; a selected container or comment has none.
        tool = match?(%Spec.Node{}, Edit.find(assigns.spec, assigns.selected))

        # On a phone, a selected tool's rows show at once.
        pane = if phone?(assigns) && tool, do: "results", else: assigns.pane

        assigns = %{
          assigns
          | status: run_status(run, tool && assigns.selected),
            rows: rows,
            results: run.tables,
            # Columns of the tools that ran; the others keep their last.
            schemas: Map.merge(assigns.schemas, schemas),
            pane: pane,
            run: %{
              nodes: run.nodes,
              disabled: run.disabled,
              messages: canvas_order(run.messages, assigns.spec)
            }
        }

        {:noreply, refresh(assigns)}

      {:error, reason} ->
        status = {:danger, "The workflow can't run yet.", Spec.format_error(reason)}
        {:noreply, clear_run(%{assigns | status: status})}
    end
  end

  def handle_info(:dismiss_toast, assigns), do: {:noreply, %{assigns | toast: nil}}

  # A run reports in the order it ran; Messages lists tools as the workflow
  # does (sorting is stable, so each tool's messages keep their order).
  defp canvas_order(messages, spec) do
    index = spec.nodes |> Enum.with_index() |> Map.new(fn {node, i} -> {node.id, i} end)
    Enum.sort_by(messages, &index[&1.node])
  end

  # The run callout: where it failed and why, how many warnings, or success.
  defp run_status(%IxpipeCore.Run{status: :failed} = run, _selected) do
    [error | _] = IxpipeCore.Run.messages(run, :error)

    {:danger, "Failed at #{Enum.join(IxpipeCore.Run.failed(run), ", ")}.",
     disabled_hint(error.text, run)}
  end

  defp run_status(run, selected) do
    case length(IxpipeCore.Run.messages(run, :warning)) do
      0 ->
        hint =
          if selected,
            do: "Results shows #{selected}.",
            else: "Select a tool to see its rows in Results."

        {:success, "Run succeeded", disabled_hint(hint, run)}

      n ->
        {:warning, "Ran with #{plural(n, "warning")}",
         disabled_hint("Messages lists what to check.", run)}
    end
  end

  defp disabled_hint(hint, %IxpipeCore.Run{disabled: []}), do: hint

  defp disabled_hint(hint, %IxpipeCore.Run{disabled: disabled}),
    do: "#{hint} #{plural(length(disabled), "tool")} skipped: disabled, or after one."

  # Why the last run skipped `node`, as its info message says, or nil.
  defp skip_reason(%{nodes: nodes, messages: messages}, %Spec.Node{id: id}) do
    if nodes[id] == :skipped,
      do: Enum.find_value(messages, &(&1.node == id and &1.level == :info and &1.text))
  end

  defp skip_reason(_run, _node), do: nil

  defp home(assigns) do
    files =
      for file <- assigns.dir |> File.ls!() |> Enum.sort(),
          String.ends_with?(file, ".yaml"),
          file != "connections.yaml",
          do:
            {file, modified(Path.join(assigns.dir, file)),
             Macro.file?(Path.join(assigns.dir, file))}

    %{
      assigns
      | files: files,
        spec: nil,
        path: nil,
        from: nil,
        status: nil,
        toast: nil,
        schemas: %{},
        pane: "canvas",
        trail: []
    }
    |> clear_run()
  end

  defp open(assigns, path) do
    case path |> File.read!() |> Spec.decode(path: path) do
      {:ok, spec} ->
        clear_run(%{
          assigns
          | spec: spec |> place() |> fit_boxes(),
            path: path,
            error: nil,
            status: nil,
            schemas: %{},
            selected: nil
        })

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
        status: nil
    }
    |> clear_run()
  end

  # Forgets the last run's results (its database goes with them), keeping
  # its columns for Select's editor.
  defp clear_run(assigns),
    do: %{assigns | rows: %{}, results: %{}, run: nil, grid: nil, profile: nil}

  # Pans so tool `id`'s card is in view when it isn't, near the canvas's top
  # left. The visible canvas is the window less its fixed chrome: on a wide
  # window the properties panel (320px), the header and ribbon (at most
  # 210px with two ribbon rows) and Results (280px); on a phone the header,
  # ribbon and tab bar. Without a window size it leaves the view alone.
  defp reveal(%{width: width, height: height, zoom: zoom, pan: {px, py}} = assigns, id)
       when is_integer(width) and is_integer(height) do
    %{position: %{"x" => x, "y" => y}} = Enum.find(assigns.spec.nodes, &(&1.id == id))

    {view_w, view_h} = view_size(assigns)

    {sx, sy} = {scaled(x + px, zoom), scaled(y + py, zoom)}
    {w, h} = {scaled(@node_width, zoom), scaled(@new_card_height, zoom)}

    if sx >= 0 and sy >= 0 and sx + w <= view_w and sy + h <= view_h do
      assigns
    else
      margin = round(20 * 100 / zoom)
      %{assigns | pan: {margin - x, margin - y}}
    end
  end

  defp reveal(assigns, _id), do: assigns

  # Where something new goes: a step down and right for each thing there.
  defp free_spot(spec) do
    n = length(spec.nodes) + length(spec.containers) + length(spec.comments)
    %{"x" => 40 + 30 * n, "y" => 40 + 30 * n}
  end

  # Where a new tool goes: open space in view, when the window's size is
  # known and there is some; else the first open space anywhere (and
  # `reveal/2` pans to it).
  defp new_spot(assigns) do
    size = {@node_width, @new_card_height}

    case view(assigns) do
      nil ->
        open_space(assigns.spec, size)

      {x0, y0, x1, y1} ->
        spots =
          for y <- y0..max(y1 - @new_card_height, y0)//20,
              x <- x0..max(x1 - @node_width, x0)//20,
              do: {x, y}

        open_spot(assigns.spec, size, spots) || open_space(assigns.spec, size)
    end
  end

  # The canvas area in view, `{x0, y0, x1, y1}` in canvas coordinates, or
  # nil without a window size (see `reveal/2` for the chrome around it).
  defp view(%{width: width, height: height, zoom: zoom, pan: {px, py}} = assigns)
       when is_integer(width) and is_integer(height) do
    {w, h} = view_size(assigns)
    unscale = &round(&1 * 100 / zoom)
    {max(-px, 0) + 20, max(-py, 0), -px + unscale.(w), -py + unscale.(h)}
  end

  defp view(_assigns), do: nil

  defp view_size(%{width: width, height: height} = assigns),
    do: if(phone?(assigns), do: {width, height - 260}, else: {width - 321, height - 491})

  # The first spot, top to bottom and left to right, where a `{width,
  # height}` box clears everything on the canvas; else below it all.
  defp open_space(spec, size) do
    case open_spot(spec, size, for(y <- 0..600//20, x <- 20..820//20, do: {x, y})) do
      nil ->
        bottom =
          Enum.max(Enum.map(extents(spec, 100, %{}), &(elem(&1, 1) + elem(&1, 3))), fn -> 0 end)

        %{"x" => 40, "y" => bottom + 24}

      at ->
        at
    end
  end

  # The first of `spots` where a `{width, height}` box clears everything.
  defp open_spot(spec, {w, h}, spots) do
    taken = extents(spec, 100, %{})
    clear? = fn {x, y} -> Enum.all?(taken, &(not overlap?({x, y, w, h}, &1))) end

    case Enum.find(spots, clear?) do
      {x, y} -> %{"x" => x, "y" => y}
      nil -> nil
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
        Tools.inputs(node) == [] -> 37 * div(length(outs) + 1, 2)
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
        selected: selected,
        drafts: %{},
        errors: %{},
        type_open: nil
    }
    |> clear_run()
  end

  defp select(assigns, id) do
    %{
      assigns
      | selected: id,
        output: nil,
        drafts: %{},
        errors: %{},
        formula_rows: 1,
        code_rows: 1,
        typing: nil,
        type_open: nil,
        browse: @browse
    }
    |> refresh()
  end

  # Applies `fun` (config, input schema -> config) to the selected Select.
  # Edits with the same `step` in a row are one undo step.
  defp edit_select(assigns, fun, step \\ nil) do
    node = Enum.find(assigns.spec.nodes, &(&1.id == assigns.selected))
    schema = input_schema(assigns.spec, node, assigns.schemas) || []
    step = step && {:config, node.id, step}
    edit(assigns, &Edit.update_config(&1, node.id, fn config -> fun.(config, schema) end), step)
  end

  # The last run's columns of what feeds `node`'s input, or nil.
  defp input_schema(spec, node, schemas) do
    with ref when is_binary(ref) <- node.inputs["in"],
         {from, output} = Spec.source(ref),
         %{} = source <- Enum.find(spec.nodes, &(&1.id == from)) do
      schemas[if(output, do: ref, else: output_key(source, nil))]
    else
      _ -> nil
    end
  end

  # What Results shows for the selected tool's output: a page of its rows,
  # or its columns' profile, read from the run's table.
  defp refresh(%{spec: nil} = assigns), do: assigns

  defp refresh(assigns) do
    node = Enum.find(assigns.spec.nodes, &(&1.id == assigns.selected))
    table = node && assigns.results[output_key(node, assigns.output)]

    cond do
      table == nil ->
        %{assigns | grid: nil, profile: nil}

      assigns.browse.view == "profile" ->
        %{assigns | grid: nil, profile: Profile.columns(table)}

      true ->
        total = assigns.rows[table.name] || Table.count(table)
        last = max(div(total - 1, @page_rows), 0)
        browse = %{assigns.browse | page: min(assigns.browse.page, last)}
        offset = browse.page * @page_rows

        {columns, rows} =
          Table.page(table, offset: offset, limit: @page_rows, sort: browse.sort)

        numeric = for {name, type} <- Table.schema(table), Profile.numeric?(type), do: name

        grid = %{
          columns: columns,
          rows: Enum.map(rows, &Enum.map(&1, fn v -> cell(v) end)),
          numeric: numeric,
          offset: offset,
          total: total
        }

        %{assigns | browse: browse, grid: grid, profile: nil}
    end
  end

  defp formulas_text(rows),
    do: rows |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.join("\n")

  # Puts `text` into the expression being typed (else the tool's first
  # expression, or its last formula row): after it (`:append`), or in place
  # of the word at its end (`:complete`).
  defp insert(assigns, text, how) do
    node = Enum.find(assigns.spec.nodes, &(&1.id == assigns.selected))

    case node && insert_target(assigns, node) do
      nil ->
        assigns

      {"formulas", i} ->
        lines = formula_lines(node, assigns.drafts)
        count = max(length(lines), formula_rows(assigns))
        rows = lines ++ List.duplicate("", count - length(lines))
        rows = List.update_at(rows, i - 1, &put_text(&1, text, how))
        configure(%{assigns | typing: {"formulas", i}}, "formulas", formulas_text(rows), rows)

      key ->
        field = Enum.find(Tools.fields(node), &(&1.key == key))
        current = assigns.drafts[key] || Config.format(field, node.config[key])
        new = put_text(current, text, how)
        configure(%{assigns | typing: key}, key, new, new)
    end
  end

  defp insert_target(assigns, node) do
    fields = Tools.fields(node)

    case assigns.typing do
      {"formulas", _} = row ->
        if Enum.any?(fields, &(&1.type == :formulas)), do: row

      key when is_binary(key) ->
        if Enum.any?(fields, &(&1.key == key and &1.type == :expr)), do: key

      nil ->
        nil
    end ||
      Enum.find_value(fields, fn
        %{type: :expr, key: key} -> key
        %{type: :formulas} -> {"formulas", formula_rows(assigns)}
        _ -> nil
      end)
  end

  defp put_text(current, text, :complete),
    do:
      String.slice(current, 0, String.length(current) - String.length(Functions.word(current))) <>
        text

  defp put_text(current, text, :append) do
    if current == "" or String.ends_with?(current, [" ", "("]),
      do: current <> text,
      else: current <> " " <> text
  end

  # Applies a setting typed or chosen in the properties panel. What was typed
  # stays as a draft, so the input never rewrites it; an invalid value shows
  # why and leaves the workflow as it was.
  defp configure(assigns, key, text, draft) do
    drafts = if draft, do: Map.put(assigns.drafts, key, draft), else: assigns.drafts
    macro? = key == "path" and match?(%{tool: Tools.Macro}, selected(assigns))
    dir = Path.dirname(assigns.path)
    # A macro's path is kept relative to this workflow, and reloads it.
    text = if macro?, do: Path.relative_to(text, dir), else: text

    case Edit.set_config(assigns.spec, assigns.selected, key, text) do
      {:ok, spec} ->
        spec = if macro?, do: Macro.attach(spec, dir, [Path.expand(assigns.path)]), else: spec

        assigns = edit(assigns, fn _ -> spec end, {:config, assigns.selected, key})
        %{assigns | drafts: drafts, errors: Map.delete(assigns.errors, key)}

      {:error, message} ->
        %{assigns | drafts: drafts, errors: Map.put(assigns.errors, key, message)}
    end
  end

  defp selected(assigns), do: Enum.find(assigns.spec.nodes, &(&1.id == assigns.selected))

  defp formula_rows(assigns) do
    node = Enum.find(assigns.spec.nodes, &(&1.id == assigns.selected))
    lines = formula_lines(node, assigns.drafts)
    max(length(lines), assigns.formula_rows)
  end

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
        {port, in_slot} <- Enum.with_index(Tools.inputs(node)),
        ref = node.inputs[port],
        {from, output} = Spec.source(ref || ""),
        source = by_id[from],
        outputs = Tools.outputs(source),
        do: {source, node, Enum.find_index(outputs, &(&1 == output)) || 0, in_slot}
  end

  defp multi?(node), do: length(Tools.outputs(node)) > 1

  # A connector per output: `{label, wire source, accessible name}`.
  defp connectors(node) do
    case Tools.outputs(node) do
      [_] -> [{"out", node.id, "Connect from #{node.id}"}]
      outs -> for out <- outs, do: {out, "#{node.id}.#{out}", "Connect from #{node.id} #{out}"}
    end
  end

  # The run result Results shows for `node`: its own, or the chosen output.
  defp output_key(node, chosen) do
    case Tools.outputs(node) do
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
  attr(:output, :string, default: nil)
  attr(:total, :integer, default: nil)
  attr(:grid, :map, default: nil)
  attr(:profile, :list, default: nil)
  attr(:browse, :map, required: true)
  attr(:skip, :string, default: nil)
  attr(:failure, :string, default: nil)
  attr(:phone, :boolean, default: false)

  # Browse, as in Alteryx: every row a page at a time, sorted by a column
  # header, or a profile of each column. Read from the run's tables.
  defp results(assigns) do
    ~H"""
    <section class={"flex-col gap-2 p-4 " <> if(@phone, do: "flex-1", else: "h-[280px]")} aria-label="Results">
      <div class="flex-row flex-wrap items-center justify-between gap-2">
        <div class="flex-row items-center gap-2">
          <.panel_header phone={@phone} panel="results" title="Results" />
          <.caption :if={@total}>{@output} · {plural(@total, "row")}</.caption>
        </div>
        <div :if={@total} class="flex-row flex-wrap items-center gap-1">
          <div :if={@grid} class="flex-row items-center gap-1">
            <.caption>{page_range(@grid)}</.caption>
            <.button variant={:quiet} size={touch(@phone, :sm)} icon="chevron-left" phx-click="page" phx-value-by="-1"
              disabled={@grid.offset == 0} aria-label="Previous page" title="Previous page" />
            <.button variant={:quiet} size={touch(@phone, :sm)} icon="chevron-right" phx-click="page" phx-value-by="1"
              disabled={@grid.offset + length(@grid.rows) >= @grid.total} aria-label="Next page" title="Next page" />
          </div>
          <.button :for={{view, label, icon} <- [{"data", "Data", "table"}, {"profile", "Profile", "chart-column"}]}
            size={touch(@phone, :sm)} icon={icon} phx-click="browse_view" phx-value-view={view}
            aria-label={"Show #{String.downcase(label)}"}
            class={if @browse.view == view, do: "border-primary bg-primary/12", else: ""}>{label}</.button>
        </div>
      </div>
      <div :if={@node && multi?(@node)} class="flex-row gap-1">
        <.button :for={out <- Tools.outputs(@node)} size={touch(@phone, :sm)} phx-click="show_output"
          phx-value-output={out} aria-label={"Show #{out} output"}
          class={if @output == "#{@node.id}.#{out}", do: "border-primary bg-primary/12", else: ""}>
          {out}
        </.button>
      </div>
      <.caption :if={!@node}>Select a tool to see its results.</.caption>
      <.caption :if={@node && !@total && @skip}>{@skip}</.caption>
      <.caption :if={@node && !@total && !@skip && !@failure}>Run the workflow to see this tool's results.</.caption>
      <div :if={@failure} class="flex-col flex-1 overflow-scroll" aria-label="Error details">
        <.body :for={line <- String.split(@failure, "\n")} class="font-mono">{indented(line)}</.body>
      </div>
      <div :if={@grid} class="flex-col flex-1 overflow-scroll">
        <table class="flex-col" aria-label="Rows">
          <tr class="flex-row py-1">
            <th :for={column <- @grid.columns} class="w-[140px] px-2">
              <.button variant={:quiet} size={touch(@phone, :sm)} phx-click="sort" phx-value-column={column}
                icon={sort_icon(@browse.sort, column)} aria-label={"Sort by #{column}"}
                class={if column in @grid.numeric, do: "w-full px-0 justify-end", else: "w-full px-0"}>
                <.label>{column}</.label>
              </.button>
            </th>
          </tr>
          <div class="h-px bg-border" />
          <tr :for={row <- @grid.rows} class="flex-row py-1">
            <td :for={{value, column} <- Enum.zip(row, @grid.columns)} class="w-[140px] px-2">
              <.body class={cell_class(value, column in @grid.numeric)}>{value}</.body>
            </td>
          </tr>
        </table>
      </div>
      <div :if={@profile} class="flex-col flex-1 overflow-scroll">
        <table class="flex-col" aria-label="Profile">
          <tr class="flex-row py-1">
            <th :for={{label, width} <- profile_columns()} class={"#{width} px-2"}><.label>{label}</.label></th>
          </tr>
          <div class="h-px bg-border" />
          <tr :for={column <- @profile} class="flex-row items-center py-1">
            <td class="w-[140px] px-2"><.body>{column.name}</.body></td>
            <td class="w-[120px] px-2"><.caption>{column.type}</.caption></td>
            <td class="w-[100px] px-2"><.body class={if column.nulls == 0, do: "text-muted-foreground", else: ""}>{share(column.nulls, column.count)}</.body></td>
            <td class="w-[80px] px-2"><.body>{column.distinct}</.body></td>
            <td class="w-[240px] px-2"><.body>{profile_values(column)}</.body></td>
            <td class="w-[120px] px-2">
              <div :if={column.bins != []} class="flex-row items-end gap-1 h-[24px]"
                aria-label={"Distribution of #{column.name}"}>
                <div :for={h <- bar_heights(column.bins)} class={"w-[6px] h-[#{h}px] bg-muted-foreground"} />
              </div>
            </td>
          </tr>
        </table>
      </div>
    </section>
    """
  end

  defp page_range(%{total: 0}), do: "No rows"

  defp page_range(%{offset: offset, rows: rows}),
    do: "Rows #{offset + 1}–#{offset + length(rows)}"

  defp sort_icon({column, :asc}, column), do: "arrow-up"
  defp sort_icon({column, :desc}, column), do: "arrow-down"
  defp sort_icon(_sort, _column), do: nil

  defp profile_columns,
    do: [
      {"Column", "w-[140px]"},
      {"Type", "w-[120px]"},
      {"Nulls", "w-[100px]"},
      {"Distinct", "w-[80px]"},
      {"Values", "w-[240px]"},
      {"Distribution", "w-[120px]"}
    ]

  # "0", or "3 (2.5%)" of the rows.
  defp share(0, _total), do: "0"

  defp share(n, total),
    do:
      "#{n} (#{:erlang.float_to_binary(n * 100 / total, [:short])}%)"
      |> String.replace(".0%", "%")

  # A number's or date's range, or anything else's most common values.
  defp profile_values(%{min: nil, max: nil, top: []}), do: "—"
  defp profile_values(%{top: [], min: min, max: max}), do: "#{cell(min)} – #{cell(max)}"

  defp profile_values(%{top: top}),
    do: Enum.map_join(top, ", ", fn {value, n} -> "#{value} (#{n})" end)

  # Bar heights in pixels, up to 24: an empty bin is a 1px baseline.
  defp bar_heights(bins) do
    top = Enum.max(bins)
    for n <- bins, do: if(n == 0, do: 1, else: max(2, round(n * 24 / top)))
  end

  attr(:phone, :boolean, required: true)
  attr(:panel, :string, required: true)
  attr(:title, :string, required: true)

  # On a wider window, the Results and Messages tabs; on a phone, the tab
  # bar names the pane, so a title.
  defp panel_header(assigns) do
    ~H"""
    <.section :if={@phone}>{@title}</.section>
    <.tabs :if={!@phone} tabs={panels()} selected={@panel} event="panel" />
    """
  end

  attr(:run, :map, default: nil)
  attr(:id, :string, required: true)

  # A card's run outcome beyond its rows: failed, skipped, or warned.
  defp run_badge(assigns) do
    assigns =
      Map.merge(assigns, %{
        state: assigns.run && assigns.run.nodes[assigns.id],
        warnings:
          if(assigns.run,
            do:
              Enum.count(assigns.run.messages, &(&1.node == assigns.id and &1.level == :warning)),
            else: 0
          )
      })

    ~H"""
    <.status_badge :if={@state == :failed} tone={:danger}>Error</.status_badge>
    <.status_badge :if={@state == :skipped} tone={:neutral}>Skipped</.status_badge>
    <.status_badge :if={@state == :ok && @warnings > 0} tone={:warning}>{plural(@warnings, "warning")}</.status_badge>
    """
  end

  attr(:run, :map, default: nil)
  attr(:level, :string, required: true)
  attr(:spec, :map, required: true)
  attr(:phone, :boolean, default: false)

  # The last run's messages, by tool in workflow order, filtered by level.
  # Choosing one selects its tool; a raw error is its tooltip.
  defp messages(assigns) do
    messages = if assigns.run, do: assigns.run.messages, else: []

    shown =
      Enum.filter(
        messages,
        &(assigns.level == "all" or Atom.to_string(&1.level) == assigns.level)
      )

    tools = Map.new(assigns.spec.nodes, &{&1.id, tool_label(Tools.name(&1.tool))})

    assigns =
      Map.merge(assigns, %{
        groups: Enum.chunk_by(shown, & &1.node),
        tools: tools,
        counts:
          Map.put(
            Enum.frequencies_by(messages, &Atom.to_string(&1.level)),
            "all",
            length(messages)
          )
      })

    ~H"""
    <section class={"flex-col gap-2 p-4 " <> if(@phone, do: "flex-1", else: "h-[280px]")} aria-label="Messages">
      <div class="flex-row items-center gap-2">
        <.panel_header phone={@phone} panel="messages" title="Messages" />
      </div>
      <.empty_state :if={!@run} title="No messages yet">Run the workflow to see each tool's messages.</.empty_state>
      <div :if={@run} class="flex-row flex-wrap gap-1" role="group" aria-label="Message levels">
        <.button :for={{key, label, name} <- levels()} size={touch(@phone, :sm)} phx-click="level"
          phx-value-level={key} aria-label={name}
          class={if @level == key, do: "border-primary bg-primary/12", else: ""}>
          {label} {@counts[key] || 0}
        </.button>
      </div>
      <.caption :if={@run && @groups == []}>No {level_noun(@level)} in the last run.</.caption>
      <div :if={@groups != []} class="flex-col gap-3 flex-1 overflow-y-scroll">
        <div :for={[%{node: node} | _] = group <- @groups} class="flex-col gap-1">
          <div class="flex-row items-center gap-2">
            <.label>{node}</.label>
            <.caption>{@tools[node]}</.caption>
          </div>
          <.list_item :for={m <- group} phx-click="select" phx-value-id={m.node}
            aria-label={"#{m.node}: #{m.text}"} title={m.detail}>
            <.status_badge tone={level_tone(m.level)}>{level_word(m.level)}</.status_badge>
            <.body class="flex-1 min-w-0">{m.text}</.body>
          </.list_item>
        </div>
      </div>
    </section>
    """
  end

  defp level_tone(:error), do: :danger
  defp level_tone(:warning), do: :warning
  defp level_tone(:info), do: :neutral
  defp level_word(:error), do: "Error"
  defp level_word(:warning), do: "Warning"
  defp level_word(:info), do: "Info"
  defp level_noun("error"), do: "errors"
  defp level_noun("warning"), do: "warnings"
  defp level_noun("info"), do: "info messages"
  defp level_noun(_), do: "messages"
  defp levels, do: @levels
  defp panels, do: @panels

  defp cell_class(value, numeric) do
    muted = if value in ["—", "0"], do: "text-muted-foreground ", else: ""
    muted <> if(numeric, do: "text-right", else: "")
  end

  attr(:node, :map, default: nil)
  attr(:item, :map, default: nil)
  attr(:drafts, :map, required: true)
  attr(:errors, :map, required: true)
  attr(:formula_rows, :integer, required: true)
  attr(:code_rows, :integer, default: 1)
  attr(:mobile, :boolean, default: false)
  attr(:dir, :string, required: true)
  attr(:phone, :boolean, default: false)
  attr(:schema, :list, default: nil)
  attr(:type_open, :integer, default: nil)
  attr(:containers, :list, default: [])
  attr(:off, :list, default: [])
  attr(:typing, :any, default: nil)
  attr(:fn_query, :string, default: "")
  attr(:fn_category, :string, default: nil)

  defp properties(assigns) do
    ~H"""
    <aside class={"flex-col gap-6 p-4 overflow-y-scroll " <> if(@phone, do: "flex-1 w-full", else: "w-[320px] shrink-0")}
      aria-label="Configuration">
      <.empty_state :if={!@item} title="Nothing selected">Select a tool to configure it.</.empty_state>
      <.container_properties :if={match?(%Spec.Container{}, @item)} container={@item} size={touch(@phone, :sm)} />
      <.comment_properties :if={match?(%Spec.Comment{}, @item)} comment={@item} size={touch(@phone, :sm)} />
      <div :if={@node} class="flex-col gap-1">
        <.section>{@node.id}</.section>
        <.caption>{node_label(@node)}</.caption>
      </div>
      <.organise :if={@node} node={@node} containers={@containers} off={@off} drafts={@drafts}
        size={touch(@phone, :sm)} />
      <.callout :if={@node && match?({:error, _}, @node.macro)} tone={:danger} title="This macro can't load.">
        {Macro.format_error(elem(@node.macro, 1))}. Choose another macro file.
      </.callout>
      <div :if={@node && match?(%Macro{}, @node.macro)} class="flex-row">
        <.button size={touch(@phone, :sm)} icon="external-link" phx-click="open_macro" aria-label="Open macro">
          Open macro
        </.button>
      </div>
      <.caption :if={@node && Tools.fields(@node) == []}>This tool has no settings.</.caption>
      <.runtime :if={@node && @node.tool == Tools.Script} node={@node} mobile={@mobile} />
      <form :if={@node} phx-change="config" aria-label="Settings" class="flex-col gap-3">
        <.field :for={field <- Tools.fields(@node)} field={field} node={@node} drafts={@drafts}
          error={@errors[field.key]} errors={@errors} formula_rows={@formula_rows} code_rows={@code_rows} dir={@dir}
          size={touch(@phone, :sm)} schema={@schema} type_open={@type_open} typing={@typing} />
      </form>
      <.function_reference :if={@node && expressions?(@node)} query={@fn_query} category={@fn_category}
        size={touch(@phone, :sm)} />
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
  attr(:code_rows, :integer, default: 1)
  attr(:dir, :string, default: nil)
  attr(:size, :atom, default: :sm)
  attr(:errors, :map, default: %{})
  attr(:schema, :list, default: nil)
  attr(:type_open, :integer, default: nil)

  attr(:typing, :any, default: nil)

  # Select's columns: a row per column (the last run's input columns, and
  # any the config lists) with a keep checkbox, its name, its type and
  # move up and down. The type opens a picker of common types and a field
  # for any other.
  defp field(%{field: %{type: :select}} = assigns) do
    rows = Select.rows(assigns.node.config, assigns.schema || [])
    # "New column" and "Not in the input" only mean something once there is
    # both a list and a run's columns to compare.
    notes? = assigns.schema != nil and assigns.node.config["columns"] not in [nil, []]

    assigns =
      Map.merge(assigns, %{rows: Enum.with_index(rows), last: length(rows) - 1, notes?: notes?})

    ~H"""
    <div class="flex-col gap-2" aria-label="Columns">
      <.label>{@field.label}</.label>
      <.empty_state :if={@rows == []} title="No columns yet">
        Run the workflow to load this tool's columns.
      </.empty_state>
      <.caption :if={@schema == nil && @rows != []}>Run the workflow to load the input's columns.</.caption>
      <div :for={{row, i} <- @rows} class="flex-col gap-1">
        <div class="flex-row items-center gap-1">
          <input type="checkbox" checked={row["keep"]} phx-click="select_keep" phx-value-index={i}
            aria-label={"Keep #{row["name"]}"} />
          <div class="flex-1 min-w-0">
            <input name={"select_name_#{i}"} value={@drafts["select_name_#{i}"] || row["rename"] || row["name"]}
              aria-label={"Name of #{row["name"]}"} class="w-full" />
          </div>
          <.button variant={:quiet} size={@size} phx-click="select_type_open" phx-value-index={i}
            aria-label={"Type of #{row["name"]}"} title="Change type"
            class={if row["type"], do: "border-primary bg-primary/12", else: ""}>
            {row["type"] || row["input_type"] || "Type"}
          </.button>
          <.button variant={:quiet} size={@size} icon="arrow-up" phx-click="select_move" phx-value-index={i}
            phx-value-by="-1" disabled={i == 0} aria-label={"Move #{row["name"]} up"} title="Move up" />
          <.button variant={:quiet} size={@size} icon="arrow-down" phx-click="select_move" phx-value-index={i}
            phx-value-by="1" disabled={i == @last} aria-label={"Move #{row["name"]} down"} title="Move down" />
        </div>
        <.caption :if={select_note(row, @notes?)} class="pl-6">{select_note(row, @notes?)}</.caption>
        <div :if={@type_open == i} class="flex-col gap-1 pl-6">
          <div class="flex-row flex-wrap gap-1">
            <.button size={@size} phx-click="select_type" phx-value-index={i} phx-value-type=""
              aria-label={"Keep #{row["name"]}'s type"}
              class={if !row["type"], do: "border-primary bg-primary/12", else: ""}>
              {row["input_type"] || "Unchanged"}
            </.button>
            <.button :for={type <- Select.common_types()} :if={type != row["input_type"]} size={@size}
              phx-click="select_type" phx-value-index={i} phx-value-type={type}
              aria-label={"Cast #{row["name"]} to #{type}"}
              class={if row["type"] == type, do: "border-primary bg-primary/12", else: ""}>{type}</.button>
          </div>
          <input name={"select_type_#{i}"} value={@drafts["select_type_#{i}"] || ""}
            placeholder="Another type, e.g. DECIMAL(10,4)" aria-label={"Another type for #{row["name"]}"} class="w-full" />
          <.caption :if={@errors["select_type_#{i}"]} class="text-danger">{@errors["select_type_#{i}"]}</.caption>
          <.caption :if={!@errors["select_type_#{i}"]}>A value that doesn't convert becomes NULL.</.caption>
        </div>
      </div>
    </div>
    """
  end

  # A tool's saved connection: the saved connections of the kinds it takes,
  # as choices, from connections.yaml in the workflows folder. An optional
  # one clears with a second click.
  defp field(%{field: %{key: "connection"}} = assigns) do
    kinds = assigns.field[:kinds] || []

    names =
      for %{"type" => type, "name" => name} <- Connections.list(assigns.dir),
          type in kinds,
          do: name

    assigns =
      Map.merge(assigns, %{
        names: names,
        cloud: kinds -- IxpipeCore.Cloud.kinds() == [],
        kinds: kinds |> Enum.map(&kind_label/1) |> Connections.join("or")
      })

    ~H"""
    <div class="flex-col gap-1">
      <div class="flex-row items-center gap-2">
        <.label>{@field.label}</.label>
        <.caption :if={@field[:optional]}>Optional</.caption>
      </div>
      <div :if={@names != []} class="flex-row flex-wrap gap-1">
        <.button :for={name <- @names} size={@size} phx-click="choose" phx-value-key="connection"
          phx-value-value={if @field[:optional] && @node.config["connection"] == name, do: "", else: name}
          aria-label={"Connection #{name}"}
          class={if @node.config["connection"] == name, do: "border-primary bg-primary/12", else: ""}>
          {name}
        </.button>
      </div>
      <.caption :if={@names == [] && !@cloud}>
        No saved connections yet. Add {@kinds} connection to connections.yaml in {@dir}.
      </.caption>
      <.caption :if={@names == [] && @cloud}>
        No saved cloud connections yet. Public buckets need none; for others, add {@kinds} connection to connections.yaml in {@dir}.
      </.caption>
      <.caption :if={@names != [] && @field[:hint]}>{@field.hint}</.caption>
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
      <%= for {line, i} <- @lines do %>
        <input name={"formula_#{i}"} value={line}
          placeholder="name = expression" aria-label={"Formula #{i}"} class="w-full" />
        <.completions :if={@typing == {"formulas", i}} text={line} size={@size} />
      <% end %>
      <.caption :if={@error} class="text-danger">{@error}</.caption>
      <.caption :if={!@error && @field[:hint]}>{@field.hint}</.caption>
      <div class="flex-row">
        <.button size={@size} phx-click="add_formula" aria-label="Add a formula">Add a formula</.button>
      </div>
    </div>
    """
  end

  # Code: a numbered row per line, in monospace.
  defp field(%{field: %{type: :code}} = assigns) do
    lines = code_lines(assigns.node, assigns.drafts)
    count = max(length(lines), assigns.code_rows)
    lines = Enum.with_index(lines ++ List.duplicate("", count - length(lines)), 1)
    assigns = Map.put(assigns, :lines, lines)

    ~H"""
    <div class="flex-col gap-1">
      <.label>{@field.label}</.label>
      <div class="flex-col rounded-md border border-border bg-muted p-1" aria-label={@field.label}>
        <div :for={{line, i} <- @lines} class="flex-row items-center gap-2">
          <.caption class="w-[20px] text-right">{i}</.caption>
          <input name={"code_line_#{i}"} value={line} aria-label={"#{@field.label} line #{i}"}
            class="flex-1 font-mono" />
        </div>
      </div>
      <.caption :if={@error} class="text-danger">{@error}</.caption>
      <.caption :if={!@error && @field[:hint]}>{@field.hint}</.caption>
      <div class="flex-row">
        <.button size={@size} phx-click="add_line" aria-label="Add a line">Add a line</.button>
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
    assigns = Map.put(assigns, :suggestions, suggestions(assigns.node, assigns.field.key))

    ~H"""
    <div class="flex-col gap-1">
      <div class="flex-row items-center gap-2">
        <.label>{@field.label}</.label>
        <.caption :if={@field[:optional]}>Optional</.caption>
      </div>
      <div :if={@suggestions != []} class="flex-row flex-wrap gap-1">
        <.button :for={value <- @suggestions} size={@size} phx-click="picked" phx-value-key={@field.key}
          phx-value-path={value} aria-label={"#{@field.label} #{value}"}
          class={if @node.config[@field.key] == value, do: "border-primary bg-primary/12", else: ""}>
          {value}
        </.button>
      </div>
      <input name={@field.key} value={@drafts[@field.key] || Config.format(@field, @node.config[@field.key])}
        aria-label={@field.label} class="w-full" />
      <.completions :if={@field.type == :expr && @typing == @field.key} text={@drafts[@field.key] || ""}
        size={@size} />
      <.caption :if={@error} class="text-danger">{@error}</.caption>
      <.caption :if={!@error && @field[:hint]}>{@field.hint}</.caption>
    </div>
    """
  end

  # Values a tool suggests for a setting (an Excel workbook's sheets).
  defp suggestions(node, key) do
    Code.ensure_loaded(node.tool)

    if function_exported?(node.tool, :suggestions, 2),
      do: node.tool.suggestions(key, node.config),
      else: []
  end

  @kind_labels %{
    "postgres" => "a Postgres",
    "mysql" => "a MySQL",
    "sqlserver" => "a SQL Server",
    "bigquery" => "a BigQuery",
    "sqlite" => "a SQLite",
    "s3" => "an s3",
    "gcs" => "gcs",
    "azure" => "azure"
  }
  defp kind_label(kind), do: Map.get(@kind_labels, kind, kind)

  attr(:text, :string, required: true)
  attr(:size, :atom, default: :sm)

  # Functions whose name starts with the word being typed, to complete it.
  defp completions(assigns) do
    assigns = Map.put(assigns, :functions, Functions.complete(assigns.text))

    ~H"""
    <div :if={@functions != []} class="flex-row flex-wrap items-center gap-1" aria-label="Completions">
      <.button :for={f <- @functions} variant={:quiet} size={@size} icon="square-function"
        phx-click="complete_function" phx-value-name={f.name} aria-label={"Complete #{f.name}"}
        title={f.description}>{f.name}</.button>
    </div>
    """
  end

  attr(:query, :string, default: "")
  attr(:category, :string, default: nil)
  attr(:size, :atom, default: :sm)

  # A searchable reference of DuckDB functions, by category; clicking one
  # inserts it into the expression being typed.
  defp function_reference(assigns) do
    assigns =
      Map.merge(assigns, %{
        functions: Functions.search(assigns.query, assigns.category),
        categories: [
          {"all", "All"} | for(c <- Functions.categories(), do: {c, String.capitalize(c)})
        ]
      })

    ~H"""
    <section class="flex-col gap-3" aria-label="Function reference">
      <div class="flex-col gap-1">
        <.section>Functions</.section>
        <.caption>Click a function to insert it into the expression.</.caption>
      </div>
      <input name="query" value={@query} phx-change="search_functions" placeholder="Search functions"
        aria-label="Search functions" class="w-full" />
      <div class="flex-row flex-wrap gap-1">
        <.button :for={{key, label} <- @categories} size={@size} phx-click="function_category"
          phx-value-category={key} aria-label={"Functions: #{key}"}
          class={if (@category || "all") == key, do: "border-primary bg-primary/12", else: ""}>
          {label}
        </.button>
      </div>
      <.caption :if={@functions == []}>No functions match. Try another word or category.</.caption>
      <div :for={f <- @functions} class="flex-col">
        <div class="flex-row">
          <.button variant={:quiet} size={@size} class="px-0" phx-click="insert_function" phx-value-name={f.name}
            aria-label={"Insert #{f.name}"} title="Insert into the expression">{f.signature}</.button>
        </div>
        <.caption>{f.description}</.caption>
        <.caption>{f.example} → {f.result}</.caption>
      </div>
    </section>
    """
  end

  defp expressions?(node), do: Enum.any?(Tools.fields(node), &(&1.type in [:expr, :formulas]))

  # Select's new-columns policy defaults by the shape of its list.
  defp chosen(%{key: "new_columns"}, %{tool: Select} = node), do: Select.new_columns(node.config)
  defp chosen(field, node), do: node.config[field.key] || field[:default] || hd(field.options)

  attr(:node, :map, required: true)
  attr(:mobile, :boolean, default: false)

  # Script's runtime: the one it will use, or what's missing and what to do.
  defp runtime(assigns) do
    language = assigns.node.config["language"] || "python"

    found =
      if assigns.mobile,
        do: {:error, Script.desktop_only()},
        else: Script.runtime(language, assigns.node.config["interpreter"])

    assigns = Map.merge(assigns, %{found: found, language: Script.label(language)})

    ~H"""
    <.callout :if={match?({:error, _}, @found)} tone={:warning} title={"#{@language} can't run here."}>
      {elem(@found, 1)}
    </.callout>
    <.caption :if={match?({:ok, _}, @found)}>Runs with {elem(@found, 1)}</.caption>
    """
  end

  # Leading spaces as no-break spaces, so a traceback keeps its indentation.
  defp indented(line),
    do: String.replace(line, ~r/^ +/, &String.duplicate("\u00A0", byte_size(&1)))

  # A failed tool's error in full (a traceback keeps its lines), for its
  # Results.
  defp failure(%{nodes: nodes, messages: messages}, %Spec.Node{id: id}) do
    if nodes[id] == :failed,
      do:
        Enum.find_value(
          messages,
          &(&1.node == id and &1.level == :error and (&1.detail || &1.text))
        )
  end

  defp failure(_run, _node), do: nil

  defp code_lines(nil, _drafts), do: []

  defp code_lines(node, drafts) do
    case drafts["code"] do
      nil -> String.split(node.config["code"] || "", "\n", trim: false) |> drop_empty()
      rows -> rows
    end
  end

  defp drop_empty([""]), do: []
  defp drop_empty(lines), do: lines

  # What a Select row changes, under it.
  defp select_note(row, loaded?) do
    [
      row["missing"] && loaded? && "Not in the input",
      row["new"] && loaded? && "New column",
      row["rename"] && "Renamed from #{row["name"]}",
      row["type"] && "#{row["input_type"] || "?"} → #{row["type"]}"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> nil
      notes -> Enum.join(notes, " · ")
    end
  end

  defp formula_lines(nil, _drafts), do: []

  defp formula_lines(node, drafts) do
    case drafts["formulas"] do
      nil ->
        field = Enum.find(Tools.fields(node), &(&1.key == "formulas"))

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
    "input_postgres" => "Input Postgres",
    "multi_row_formula" => "Multi-row formula",
    "multi_field_formula" => "Multi-field formula",
    "date_time" => "DateTime",
    "output_postgres" => "Output Postgres",
    "input_json" => "Input JSON",
    "output_json" => "Output JSON",
    "input_mysql" => "Input MySQL",
    "output_mysql" => "Output MySQL",
    "input_sqlserver" => "Input SQL Server",
    "output_sqlserver" => "Output SQL Server",
    "input_bigquery" => "Input BigQuery",
    "record_id" => "Record ID",
    "running_total" => "Running total",
    "generate_rows" => "Generate rows",
    "auto_field" => "Auto field",
    "find_replace" => "Find replace",
    "append_fields" => "Append fields",
    "join_multiple" => "Join multiple",
    "fuzzy_match" => "Fuzzy match",
    "macro_input" => "Macro input",
    "macro_output" => "Macro output"
  }
  defp tool_label(tool), do: Map.get_lazy(@labels, tool, fn -> String.capitalize(tool) end)

  # A macro node names its macro.
  defp node_label(%{macro: %Macro{name: name}}), do: "Macro · #{name}"
  defp node_label(node), do: tool_label(Tools.name(node.tool))

  # Workflows / the workflows a macro was opened from / this one.
  defp crumbs(trail, path) do
    parents =
      for {parent, i} <- trail |> Enum.with_index() |> Enum.reverse(),
          do: {Path.basename(parent.path), "return_#{i}"}

    [{"Workflows", "back"} | parents] ++ [Path.basename(path)]
  end

  # Lucide icons for the tool commands, as ixtable's ribbon has: an input and
  # an output share their format's icon.
  @icons %{
    "csv" => "file-text",
    "excel" => "file-spreadsheet",
    "parquet" => "file-box",
    "sqlite" => "database",
    "json" => "file-braces",
    "postgres" => "server",
    "mysql" => "database-zap",
    "sqlserver" => "server-cog",
    "bigquery" => "warehouse",
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
    "transpose" => "arrow-left-right",
    "multi_row_formula" => "rows-3",
    "multi_field_formula" => "columns-4",
    "date_time" => "calendar-clock",
    "record_id" => "hash",
    "running_total" => "trending-up",
    "tile" => "chart-column-stacked",
    "generate_rows" => "list-plus",
    "imputation" => "paint-bucket",
    "auto_field" => "wand-sparkles",
    "find_replace" => "replace",
    "append_fields" => "between-horizontal-start",
    "join_multiple" => "combine",
    "fuzzy_match" => "scan-search",
    "macro_input" => "log-in",
    "macro_output" => "log-out",
    "python" => "square-code",
    "script" => "square-terminal"
  }
  defp tool_icon(tool), do: Map.get(@icons, String.replace(tool, ~r/^(in|out)put_/, ""))

  # A shortcut as the platform writes it: Cmd on macOS, Ctrl elsewhere.
  defp shortcut(key),
    do: if(Baguette.platform() == :macos, do: "Cmd+", else: "Ctrl+") <> key

  defp ribbon_tabs, do: for({key, label, _} <- @ribbon, do: {key, label})

  defp ribbon_groups(tab),
    do: Enum.find_value(@ribbon, [], fn {key, _, groups} -> key == tab && groups end)

  defp ribbon_rows([row | _] = rows, false) when is_list(row), do: rows
  defp ribbon_rows([row | _] = rows, true) when is_list(row), do: [Enum.concat(rows)]
  defp ribbon_rows(tools, _phone), do: [tools]

  # In the Input and Output groups the group names the direction: "CSV".

  # A ribbon command's short noun: the tool's label less its group's name
  # ("CSV" in Input), or a shorter one where the group already says it.
  @commands %{"multi_row_formula" => "Multi-row", "multi_field_formula" => "Multi-field"}
  defp command_label(group, tool),
    do:
      Map.get_lazy(@commands, tool, fn ->
        tool |> tool_label() |> String.replace_prefix(group <> " ", "")
      end)

  defp phone?(%{width: width}), do: is_integer(width) and width < @phone_width
  defp panes, do: @panes

  # The phone's touch size (40px), or `size` on a wider window.
  defp touch(phone, size \\ :md)
  defp touch(true, _size), do: :touch
  defp touch(false, size), do: size

  defp node_width, do: @node_width
  defp comment_width, do: @comment_width
end
