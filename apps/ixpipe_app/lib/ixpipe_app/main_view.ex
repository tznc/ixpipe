defmodule IxpipeApp.MainView do
  @moduledoc """
  The main window: a home screen listing the workflows in a directory, and a
  canvas to build, wire, save and run one. Built from `IxpipeApp.Components`
  to the design language in AGENTS.md.

  Args: `:dir` (the workflows directory) and, optionally, `:path` to open.
  """
  use Baguette.View
  import IxpipeApp.Components

  alias IxpipeCore.{Config, Connections, Edit, Profile, Spec, Table, Tools}
  alias IxpipeCore.Tools.Select

  @node_width 200
  @port_y 24
  @toast_ms 6_000
  @zooms [50, 75, 100, 125, 150]
  @history 100
  @page_rows 50
  @browse %{page: 0, sort: nil, view: "data"}
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
      # The last run's tables, alive in its DuckDB database while Results
      # browses them, and their warnings; an edit drops them.
      results: %{},
      warnings: %{},
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
          <.empty_state :if={@spec.nodes == []} title="This workflow is empty">
            Add a tool from a ribbon tab above.
          </.empty_state>
          <%!-- The surface is as large as the furthest node, so the canvas
            scrolls to every one. --%>
          <div class="absolute left-[0px] top-[0px] size-full overflow-scroll" aria-label="Canvas">
          <%!-- Dragging the empty surface pans the view; nodes claim their own drags. --%>
          <div class={"relative #{surface(@spec, @zoom, @pan)}"} aria-label="Canvas surface"
            phx-drag="pan">
          <line :for={{from, to, out_slot, in_slot} <- edges(@spec)} curve
            x1={vx(from, @zoom, @pan) + scaled(node_width(), @zoom)}
            y1={vy(from, @zoom, @pan) + scaled(port_y() + 12 * out_slot, @zoom)}
            x2={vx(to, @zoom, @pan)} y2={vy(to, @zoom, @pan) + scaled(port_y() + 12 * in_slot, @zoom)}
            class="stroke-muted-foreground" />
          <div :for={node <- @spec.nodes} aria-label={node.id} phx-drag="move" phx-value-id={node.id}
            class={"absolute left-[#{vx(node, @zoom, @pan)}px] top-[#{vy(node, @zoom, @pan)}px] w-[#{scaled(node_width(), @zoom)}px] flex-col gap-2 rounded-md border #{if compact?(@zoom), do: "p-2", else: "p-3"} " <> card_state(node.id, @selected, @from)}>
            <div class="flex-row flex-wrap items-center justify-between gap-2">
              <.button variant={:quiet} size={:sm} class="px-0" phx-click="select" phx-value-id={node.id}
                aria-label={"Select #{node.id}"}><.section>{node.id}</.section></.button>
              <.button :if={!compact?(@zoom)} variant={:danger} size={:sm} phx-click="remove"
                phx-value-id={node.id} aria-label={"Remove #{node.id}"}>Remove</.button>
            </div>
            <div class="flex-row flex-wrap items-center gap-2">
              <.caption>{tool_label(Tools.name(node.tool))}</.caption>
              <.status_badge :if={@rows[node.id]} tone={:success}>{plural(@rows[node.id], "row")}</.status_badge>
              <.status_badge :if={@warnings[node.id]} tone={:warning}>{plural(length(@warnings[node.id]), "warning")}</.status_badge>
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
          </div>
          </div>
          <%!-- Top right of the canvas, clear of the header's buttons. --%>
          <.feedback :if={!@phone} toast={@toast} status={@status} phone={false} />
        </div>
        <div :if={!@phone} class="h-px w-full bg-border" />
        <.results :if={!@phone} node={@node} output={@node && output_key(@node, @output)}
          total={@node && @rows[output_key(@node, @output)]} grid={@grid} profile={@profile} browse={@browse}
          warnings={(@node && @warnings[output_key(@node, @output)]) || []} />
        </div>
        <.results :if={@phone && @pane == "results"} node={@node} output={@node && output_key(@node, @output)}
          total={@node && @rows[output_key(@node, @output)]} grid={@grid} profile={@profile} browse={@browse}
          warnings={(@node && @warnings[output_key(@node, @output)]) || []} phone />
        <div :if={!@phone} class="w-px h-full bg-border" />
        <.properties :if={!@phone || @pane == "properties"} node={@node} drafts={@drafts} errors={@errors}
          formula_rows={@formula_rows} dir={@dir} phone={@phone}
          schema={@node && input_schema(@spec, @node, @schemas)} type_open={@type_open} />
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

  def handle_event("add", %{"tool" => tool}, assigns) do
    at = %{
      "x" => 40 + 30 * length(assigns.spec.nodes),
      "y" => 40 + 30 * length(assigns.spec.nodes)
    }

    assigns = edit(assigns, &Edit.add_node(&1, tool, at))
    {:noreply, select(assigns, List.last(assigns.spec.nodes).id)}
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

  # Drags arrive in screen pixels; at a zoom they move the node by the
  # canvas distance under the pointer.
  def handle_event("move", %{"id" => id, "dx" => dx, "dy" => dy}, %{zoom: zoom} = assigns) do
    {dx, dy} = {round(dx * 100 / zoom), round(dy * 100 / zoom)}
    {:noreply, edit(assigns, &Edit.move_node(&1, id, dx, dy))}
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

  def handle_event("remove", %{"id" => id}, assigns) do
    assigns = edit(assigns, &Edit.remove_node(&1, id))
    {:noreply, if(assigns.selected == id, do: select(assigns, nil), else: assigns)}
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

  def handle_event("run", _values, assigns) do
    result =
      with {:ok, spec} <- Spec.validate(assigns.spec),
           do: IxpipeCore.run(with_home(spec, assigns.dir))

    case result do
      {:ok, results} ->
        rows = Map.new(results, fn {id, table} -> {id, Table.count(table)} end)
        schemas = Map.new(results, fn {id, table} -> {id, Table.schema(table)} end)
        warnings = for {id, %Table{warnings: [_ | _] = w}} <- results, into: %{}, do: {id, w}

        hint =
          if assigns.selected,
            do: "Results shows #{assigns.selected}.",
            else: "Select a tool to see its rows in Results."

        status =
          case Enum.sort(warnings) do
            [] ->
              {:success, "Run succeeded", hint}

            [{id, [first | _]} | _] ->
              n = warnings |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
              {:warning, "Run succeeded with #{plural(n, "warning")}", "#{id}: #{first} #{hint}"}
          end

        # On a phone, a selected tool's rows show at once.
        pane = if phone?(assigns) && assigns.selected, do: "results", else: assigns.pane

        assigns = %{
          assigns
          | status: status,
            rows: rows,
            results: results,
            warnings: warnings,
            schemas: schemas,
            pane: pane
        }

        {:noreply, refresh(assigns)}

      {:error, {:node_failed, id, message}} ->
        status = {:danger, "#{id} failed.", "#{message} Fix its config and run again."}
        {:noreply, clear_run(%{assigns | status: status})}

      {:error, reason} ->
        status = {:danger, "The workflow can't run yet.", Spec.format_error(reason)}
        {:noreply, clear_run(%{assigns | status: status})}
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
        schemas: %{},
        pane: "canvas"
    }
    |> clear_run()
  end

  defp open(assigns, path) do
    case path |> File.read!() |> Spec.decode() do
      {:ok, spec} ->
        clear_run(%{
          assigns
          | spec: place(spec),
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
    spec = fun.(assigns.spec)

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
    do: %{assigns | rows: %{}, results: %{}, warnings: %{}, grid: nil, profile: nil}

  # Database tools find saved connections in the workflows folder; it is
  # given for the run only, never saved into the workflow.
  defp with_home(spec, dir),
    do: %{spec | nodes: Enum.map(spec.nodes, &%{&1 | config: Map.put(&1.config, "_home", dir)})}

  defp restore(assigns, spec) do
    selected = if Enum.any?(spec.nodes, &(&1.id == assigns.selected)), do: assigns.selected

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

  # The surface covers the furthest tool at the current zoom and pan.
  defp surface(spec, zoom, {px, py}) do
    {w, h} =
      Enum.reduce(spec.nodes, {0, 0}, fn %{position: %{"x" => x, "y" => y}}, {w, h} ->
        {max(w, x + px + @node_width + 40), max(h, y + py + 160)}
      end)

    "w-[#{scaled(w, zoom)}px] h-[#{scaled(h, zoom)}px]"
  end

  defp min_position(%{nodes: []}), do: {0, 0}

  defp min_position(spec) do
    {Enum.min(Enum.map(spec.nodes, & &1.position["x"])),
     Enum.min(Enum.map(spec.nodes, & &1.position["y"]))}
  end

  # Where a tool shows: its canvas position, panned, at the zoom.
  defp vx(node, zoom, {px, _}), do: scaled(node.position["x"] + px, zoom)
  defp vy(node, zoom, {_, py}), do: scaled(node.position["y"] + py, zoom)
  defp scaled(length, zoom), do: round(length * zoom / 100)
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
  attr(:warnings, :list, default: [])
  attr(:phone, :boolean, default: false)

  # Browse, as in Alteryx: every row a page at a time, sorted by a column
  # header, or a profile of each column. Read from the run's tables.
  defp results(assigns) do
    ~H"""
    <section class={"flex-col gap-2 p-4 " <> if(@phone, do: "flex-1", else: "h-[280px]")} aria-label="Results">
      <div class="flex-row flex-wrap items-center justify-between gap-2">
        <div class="flex-row items-center gap-2">
          <.section>Results</.section>
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
        <.button :for={out <- Tools.outputs(@node.tool)} size={touch(@phone, :sm)} phx-click="show_output"
          phx-value-output={out} aria-label={"Show #{out} output"}
          class={if @output == "#{@node.id}.#{out}", do: "border-primary bg-primary/12", else: ""}>
          {out}
        </.button>
      </div>
      <div :if={@warnings != []} class="flex-row flex-wrap gap-1" aria-label="Warnings">
        <.status_badge :for={warning <- @warnings} tone={:warning}>{warning}</.status_badge>
      </div>
      <.caption :if={!@node}>Select a tool to see its results.</.caption>
      <.caption :if={@node && !@total}>Run the workflow to see this tool's results.</.caption>
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

  defp cell_class(value, numeric) do
    muted = if value in ["—", "0"], do: "text-muted-foreground ", else: ""
    muted <> if(numeric, do: "text-right", else: "")
  end

  attr(:node, :map, default: nil)
  attr(:drafts, :map, required: true)
  attr(:errors, :map, required: true)
  attr(:formula_rows, :integer, required: true)
  attr(:dir, :string, required: true)
  attr(:phone, :boolean, default: false)
  attr(:schema, :list, default: nil)
  attr(:type_open, :integer, default: nil)

  defp properties(assigns) do
    ~H"""
    <aside class={"flex-col gap-6 p-4 overflow-y-scroll " <> if(@phone, do: "flex-1 w-full", else: "w-[320px]")}
      aria-label="Configuration">
      <.empty_state :if={!@node} title="Nothing selected">Select a tool to configure it.</.empty_state>
      <div :if={@node} class="flex-col gap-1">
        <.section>{@node.id}</.section>
        <.caption>{tool_label(Tools.name(@node.tool))}</.caption>
      </div>
      <.caption :if={@node && @node.tool.fields() == []}>This tool has no settings.</.caption>
      <form :if={@node} phx-change="config" aria-label="Settings" class="flex-col gap-3">
        <.field :for={field <- @node.tool.fields()} field={field} node={@node} drafts={@drafts}
          error={@errors[field.key]} errors={@errors} formula_rows={@formula_rows} dir={@dir}
          size={touch(@phone, :sm)} schema={@schema} type_open={@type_open} />
      </form>
    </aside>
    """
  end

  attr(:field, :map, required: true)
  attr(:node, :map, required: true)
  attr(:drafts, :map, required: true)
  attr(:error, :string, default: nil)
  attr(:formula_rows, :integer, required: true)
  attr(:dir, :string, default: nil)
  attr(:size, :atom, default: :sm)
  attr(:errors, :map, default: %{})
  attr(:schema, :list, default: nil)
  attr(:type_open, :integer, default: nil)

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

  # Select's new-columns policy defaults by the shape of its list.
  defp chosen(%{key: "new_columns"}, %{tool: Select} = node), do: Select.new_columns(node.config)
  defp chosen(field, node), do: node.config[field.key] || hd(field.options)

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
  defp port_y, do: @port_y
end
