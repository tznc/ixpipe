defmodule IxpipeCore do
  @moduledoc """
  Runs workflows parsed by `IxpipeCore.Spec`: Runic orchestrates the DAG,
  and each node's output is a table in the run's DuckDB database
  (`IxpipeCore.Table`).
  """

  require Runic
  alias Runic.Workflow
  alias IxpipeCore.{Context, Duck, Spec, Table}

  @doc """
  Runs every node of `spec` in a fresh DuckDB database, returning each
  output's table by name: the node id for a tool with one output,
  `node.output` for each output of a tool with several. The tables live as
  long as a result references the database. The first node to raise fails
  the run; nodes downstream of it do not run.

  A macro run on its own takes its parameters' defaults, or `:params`.
  A failure inside a macro names the inner tool (`node/inner`).

  Options: `:settings`, DuckDB `SET` options such as `memory_limit`;
  `:params`, values for a macro workflow's parameters by name.
  """
  @spec run(Spec.t(), keyword()) ::
          {:ok, %{String.t() => Table.t()}}
          | {:error, {:node_failed, String.t(), String.t()}}
  def run(%Spec{} = spec, opts \\ []) do
    {:ok, db} = Duck.open(Keyword.get(opts, :settings, []))
    spec = IxpipeCore.Macro.bind(spec, Keyword.get(opts, :params, %{}))
    results = execute(spec, db)

    case Enum.find(Map.values(results), &match?({:failed, _, _}, &1)) do
      nil -> {:ok, results}
      {:failed, id, message} -> {:error, {:node_failed, id, message}}
    end
  end

  @doc false
  # Runs `spec` in `db`, naming its tables under `prefix`; failed nodes map
  # to `{:failed, id, message}`.
  def execute(%Spec{} = spec, db, prefix \\ "") do
    spec
    |> to_runic(db, prefix)
    |> Workflow.react_until_satisfied(:run)
    |> Workflow.raw_productions_by_component()
    |> Enum.flat_map(fn {id, [value | _]} -> flatten(id, value) end)
    |> Map.new()
  end

  @doc """
  Compiles `spec` into a Runic workflow with one step per node, working in
  `db`. Each node's tables are named for `prefix` and its id (a macro's
  inner nodes run under `node/`).
  """
  @spec to_runic(Spec.t(), Duck.db(), String.t()) :: Workflow.t()
  def to_runic(%Spec{} = spec, db, prefix \\ "") do
    nodes = Map.new(spec.nodes, &{&1.id, &1})

    Enum.reduce(spec.nodes, Runic.workflow(name: spec.name || "ixpipe"), fn node, wrk ->
      ports = IxpipeCore.Tools.inputs(node)
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

      ctx = %Context{db: db, id: prefix <> node.id}
      # A macro node's tool runs the macro it loaded.
      node =
        if node.macro,
          do: %{node | config: Map.put(node.config, "_macro", node.macro)},
          else: node

      Workflow.add(wrk, step(node, ctx, slots, length(unique)), add_opts(unique))
    end)
  end

  defp flatten(id, %Table{} = table), do: [{id, table}]
  defp flatten(id, {:failed, _, _} = failed), do: [{id, failed}]

  defp flatten(id, outputs) when is_map(outputs),
    do: for({out, table} <- outputs, do: {"#{id}.#{out}", table})

  defp add_opts([]), do: []
  defp add_opts([parent]), do: [to: parent]
  defp add_opts(parents), do: [to: parents]

  # Runic hashes a step from its fn and bound variables, so `id` sits inside
  # each fn: nodes with the same tool and config stay distinct steps.
  defp step(%{id: id, tool: tool, config: config}, ctx, slots, arity) do
    case arity do
      0 ->
        Runic.step(fn _ -> run_tool(ctx, tool, inputs(slots, []), config) end, name: id)

      1 ->
        Runic.step(fn x -> run_tool(ctx, tool, inputs(slots, [x]), config) end, name: id)

      2 ->
        Runic.step(fn x, y -> run_tool(ctx, tool, inputs(slots, [x, y]), config) end, name: id)
    end
  end

  @doc false
  def inputs(slots, args),
    do: Map.new(slots, fn {port, i, output} -> {port, pick(Enum.at(args, i), output)} end)

  defp pick(%Table{} = table, _output), do: table
  defp pick({:failed, _, _} = failed, _output), do: failed
  defp pick(outputs, output) when is_map(outputs), do: Map.fetch!(outputs, output)

  # A failure is passed downstream as a value, so the run still settles and
  # reports the node that raised.
  @doc false
  def run_tool(%Context{id: id} = ctx, tool, inputs, config) do
    case Enum.find(Map.values(inputs), &match?({:failed, _, _}, &1)) do
      nil ->
        try do
          tool.run(inputs, config, ctx)
        rescue
          e -> {:failed, id, Exception.message(e)}
        end

      failed ->
        failed
    end
  end
end
