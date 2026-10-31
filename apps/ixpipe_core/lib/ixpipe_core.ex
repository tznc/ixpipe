defmodule IxpipeCore do
  @moduledoc """
  Runs workflows parsed by `IxpipeCore.Spec`: Runic orchestrates the DAG,
  and each node's output is a table in the run's DuckDB database
  (`IxpipeCore.Table`).
  """

  require Runic
  alias Runic.Workflow
  alias IxpipeCore.{Context, Duck, Errors, Macro, Message, Run, Spec, Table}

  @doc """
  Runs every node of `spec` in a fresh DuckDB database, returning each
  output's table by name: the node id for a tool with one output,
  `node.output` for each output of a tool with several. The tables live as
  long as a result references the database. When a node fails, the run
  fails with the first (in workflow order) and its raw error; `execute/2`
  keeps what did run, and every node's messages.

  A macro run on its own takes its parameters' defaults, or `:params`.
  A failure inside a macro node fails that node, naming the inner tool
  (`m/f failed: …`).

  Options: `:settings`, DuckDB `SET` options such as `memory_limit`;
  `:params`, values for a macro workflow's parameters by name.
  """
  @spec run(Spec.t(), keyword()) ::
          {:ok, %{String.t() => Table.t()}}
          | {:error, {:node_failed, String.t(), String.t()}}
  def run(%Spec{} = spec, opts \\ []) do
    case execute(spec, opts) do
      %Run{status: :ok, tables: tables} ->
        {:ok, tables}

      run ->
        [error | _] = Run.messages(run, :error)
        {:error, {:node_failed, error.node, error.detail}}
    end
  end

  @doc """
  Runs every node of `spec`, as Alteryx does: a node that fails stops only
  the nodes downstream of it (they are skipped); every other branch runs.
  Returns an `IxpipeCore.Run`: each node's status, the tables of the nodes
  that ran, and each node's messages (its rows and time, its tool's
  warnings, and why it failed, in "what happened. what to do." form with
  DuckDB's raw error as the detail).

  Options as `run/2`, and for a macro's inner run: `:db`, the database to
  run in (instead of a fresh one), and `:prefix`, which names the run's
  tables and messages (`m/` for the inner nodes of macro node `m`). `tables`
  and `nodes` stay keyed by the spec's own ids.
  """
  @spec execute(Spec.t(), keyword()) :: Run.t()
  def execute(%Spec{} = spec, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    prefix = Keyword.get(opts, :prefix, "")
    db = Keyword.get_lazy(opts, :db, fn -> open!(opts) end)
    # A macro run on its own binds its parameters; an inner run's spec
    # already holds the node's values.
    spec = if prefix == "", do: Macro.bind(spec, Keyword.get(opts, :params, %{})), else: spec
    log = Context.new_log()

    try do
      produced =
        spec
        |> to_runic(db, log, prefix)
        |> Workflow.react_until_satisfied(:run)
        |> Workflow.raw_productions_by_component()
        |> Map.new(fn {id, [value | _]} -> {id, value} end)

      nodes =
        Map.new(spec.nodes, fn %{id: id} ->
          status =
            case produced[id] do
              {:failed, _, _} -> :failed
              {:skipped, _, _} -> :skipped
              nil -> :skipped
              _ -> :ok
            end

          {id, status}
        end)

      tables =
        for {id, value} <- produced,
            nodes[id] == :ok,
            pair <- flatten(id, value),
            into: %{},
            do: pair

      order = spec.nodes |> Enum.with_index() |> Map.new(fn {node, i} -> {node.id, i} end)

      # Sorting is stable: within a level, a node's messages stay in the
      # order it recorded them.
      messages =
        %Context{db: db, id: nil, log: log}
        |> Context.messages()
        |> Enum.sort_by(&{order[&1.node], Message.rank(&1.level)})

      %Run{
        status: if(Enum.any?(Map.values(nodes), &(&1 == :failed)), do: :failed, else: :ok),
        nodes: nodes,
        tables: tables,
        messages: messages,
        ms: System.monotonic_time(:millisecond) - started
      }
    after
      :ets.delete(log)
    end
  end

  @doc """
  Compiles `spec` into a Runic workflow with one step per node, working in
  `db` and recording messages in `log`. Each node's tables (and messages)
  are named for `prefix` and its id: a macro's inner nodes run under
  `node/`.
  """
  @spec to_runic(Spec.t(), Duck.db(), Context.log(), String.t()) :: Workflow.t()
  def to_runic(%Spec{} = spec, db, log \\ nil, prefix \\ "") do
    nodes = Map.new(spec.nodes, &{&1.id, &1})

    Enum.reduce(spec.nodes, Runic.workflow(name: spec.name || "ixpipe"), fn node, wrk ->
      # Only the connected ports: an optional one may be left open.
      ports = Enum.filter(IxpipeCore.Tools.inputs(node), &Map.has_key?(node.inputs, &1))
      sources = Enum.map(ports, &Spec.source(node.inputs[&1]))
      # A Runic join never fires on a repeated parent, so each parent node
      # feeds the step once; `slots` maps every port to its parent's
      # argument and the output it reads (the first, when unnamed).
      unique = sources |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      slots =
        for {port, {from, output}} <- Enum.zip(ports, sources) do
          index = Enum.find_index(unique, &(&1 == from))
          {port, index, output || hd(IxpipeCore.Tools.outputs(nodes[from]))}
        end

      ctx = %Context{db: db, id: prefix <> node.id, log: log}
      # A macro node's tool runs the macro it loaded.
      node =
        if node.macro,
          do: %{node | config: Map.put(node.config, "_macro", node.macro)},
          else: node

      Workflow.add(wrk, step(node, ctx, slots, length(unique)), add_opts(unique))
    end)
  end

  defp open!(opts) do
    {:ok, db} = Duck.open(Keyword.get(opts, :settings, []))
    db
  end

  defp flatten(id, %Table{} = table), do: [{id, table}]

  defp flatten(id, outputs) when is_map(outputs),
    do: for({out, table} <- outputs, do: {"#{id}.#{out}", table})

  defp add_opts([]), do: []
  defp add_opts([parent]), do: [to: parent]
  defp add_opts(parents), do: [to: parents]

  # Runic hashes a step from its fn and bound variables, so `id` sits inside
  # each fn: nodes with the same tool and config stay distinct steps.
  defp step(%{id: id, config: config} = node, ctx, slots, arity) do
    # The tool with its node's outputs, in order, for the rows message.
    tool = {node.tool, IxpipeCore.Tools.outputs(node)}

    case arity do
      0 ->
        Runic.step(fn _ -> run_tool(ctx, tool, inputs(slots, []), config) end, name: id)

      1 ->
        Runic.step(fn x -> run_tool(ctx, tool, inputs(slots, [x]), config) end, name: id)

      2 ->
        Runic.step(fn x, y -> run_tool(ctx, tool, inputs(slots, [x, y]), config) end, name: id)

      3 ->
        Runic.step(fn x, y, z -> run_tool(ctx, tool, inputs(slots, [x, y, z]), config) end,
          name: id
        )

      4 ->
        Runic.step(
          fn w, x, y, z -> run_tool(ctx, tool, inputs(slots, [w, x, y, z]), config) end,
          name: id
        )
    end
  end

  @doc false
  def inputs(slots, args),
    do: Map.new(slots, fn {port, i, output} -> {port, pick(Enum.at(args, i), output)} end)

  defp pick(%Table{} = table, _output), do: table
  defp pick({:failed, _, _} = failed, _output), do: failed
  defp pick({:skipped, _, _} = skipped, _output), do: skipped
  defp pick(outputs, output) when is_map(outputs), do: Map.fetch!(outputs, output)

  # A failure is passed downstream as a value, so the run still settles:
  # nodes below it are skipped, naming the node that failed, and the other
  # branches run on.
  @doc false
  def run_tool(ctx, tool, inputs, config)

  def run_tool(ctx, tool, inputs, config) when is_atom(tool),
    do: run_tool(ctx, {tool, IxpipeCore.Tools.outputs(tool)}, inputs, config)

  def run_tool(%Context{id: id} = ctx, {tool, outputs}, inputs, config) do
    case Enum.find_value(Map.values(inputs), &cause/1) do
      nil ->
        started = System.monotonic_time(:millisecond)

        try do
          result = tool.run(inputs, config, ctx)
          ms = System.monotonic_time(:millisecond) - started
          Context.info(ctx, "#{rows(outputs, result)} in #{ms} ms")
          result
        rescue
          # A macro's inner tool failed: its message, naming that tool.
          e in Macro.Failed ->
            Context.record(ctx, :error, e.text, e.detail)
            {:failed, id, e.detail}

          e ->
            failed(ctx, Exception.message(e))
        catch
          kind, reason -> failed(ctx, Exception.format_banner(kind, reason))
        end

      cause ->
        Context.info(ctx, "Didn't run because #{cause} failed. Fix #{cause} and run again.")
        {:skipped, id, cause}
    end
  end

  defp cause({:failed, id, _}), do: id
  defp cause({:skipped, _, cause}), do: cause
  defp cause(_), do: nil

  defp failed(%Context{id: id} = ctx, raw) do
    Context.record(ctx, :error, Errors.humanize(raw), raw)
    {:failed, id, raw}
  end

  defp rows(_names, %Table{} = table), do: plural(Table.count(table), "row")

  defp rows(names, outputs) when is_map(outputs) do
    names
    |> Enum.filter(&Map.has_key?(outputs, &1))
    |> Enum.map_join(", ", &"#{&1} #{plural(Table.count(outputs[&1]), "row")}")
  end

  @doc false
  def plural(1, noun), do: "1 #{noun}"
  def plural(n, noun), do: "#{n} #{noun}s"
end
