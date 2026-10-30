defmodule IxpipeCore do
  @moduledoc "Runs workflows parsed by `IxpipeCore.Spec`."

  require Runic
  alias Runic.Workflow
  alias IxpipeCore.Spec

  @doc """
  Runs every node of `spec`, returning each output by name: the node id for
  a tool with one output, `node.output` for each output of a tool with
  several. The first node to raise fails the run; nodes downstream of it do
  not run.
  """
  @spec run(Spec.t()) ::
          {:ok, %{String.t() => Explorer.DataFrame.t()}}
          | {:error, {:node_failed, String.t(), String.t()}}
  def run(%Spec{} = spec) do
    results =
      spec
      |> to_runic()
      |> Workflow.react_until_satisfied(:run)
      |> Workflow.raw_productions_by_component()
      |> Enum.flat_map(fn {id, [value | _]} -> flatten(id, value) end)
      |> Map.new()

    case Enum.find(Map.values(results), &match?({:failed, _, _}, &1)) do
      nil -> {:ok, results}
      {:failed, id, message} -> {:error, {:node_failed, id, message}}
    end
  end

  @doc "Compiles `spec` into a Runic workflow with one step per node."
  @spec to_runic(Spec.t()) :: Workflow.t()
  def to_runic(%Spec{} = spec) do
    tools = Map.new(spec.nodes, &{&1.id, &1.tool})

    Enum.reduce(spec.nodes, Runic.workflow(name: spec.name || "ixpipe"), fn node, wrk ->
      ports = node.tool.inputs()
      sources = Enum.map(ports, &Spec.source(node.inputs[&1]))
      # A Runic join never fires on a repeated parent, so each parent node
      # feeds the step once; `slots` maps every port to its parent's
      # argument and the output it reads (the first, when unnamed).
      unique = sources |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      slots =
        for {port, {from, output}} <- Enum.zip(ports, sources) do
          index = Enum.find_index(unique, &(&1 == from))
          {port, index, output || hd(IxpipeCore.Tools.outputs(tools[from]))}
        end

      Workflow.add(wrk, step(node, slots, length(unique)), add_opts(unique))
    end)
  end

  defp flatten(id, %Explorer.DataFrame{} = df), do: [{id, df}]
  defp flatten(id, {:failed, _, _} = failed), do: [{id, failed}]

  defp flatten(id, outputs) when is_map(outputs),
    do: for({out, df} <- outputs, do: {"#{id}.#{out}", df})

  defp add_opts([]), do: []
  defp add_opts([parent]), do: [to: parent]
  defp add_opts(parents), do: [to: parents]

  # Runic hashes a step from its fn and bound variables, so `id` sits inside
  # each fn: nodes with the same tool and config stay distinct steps.
  defp step(%{id: id, tool: tool, config: config}, slots, arity) do
    case arity do
      0 ->
        Runic.step(fn _ -> run_tool(id, tool, inputs(slots, []), config) end, name: id)

      1 ->
        Runic.step(fn x -> run_tool(id, tool, inputs(slots, [x]), config) end, name: id)

      2 ->
        Runic.step(fn x, y -> run_tool(id, tool, inputs(slots, [x, y]), config) end, name: id)
    end
  end

  @doc false
  def inputs(slots, args),
    do: Map.new(slots, fn {port, i, output} -> {port, pick(Enum.at(args, i), output)} end)

  defp pick(%Explorer.DataFrame{} = df, _output), do: df
  defp pick({:failed, _, _} = failed, _output), do: failed
  defp pick(outputs, output) when is_map(outputs), do: Map.fetch!(outputs, output)

  # A failure is passed downstream as a value, so the run still settles and
  # reports the node that raised.
  @doc false
  def run_tool(id, tool, inputs, config) do
    case Enum.find(Map.values(inputs), &match?({:failed, _, _}, &1)) do
      nil ->
        try do
          tool.run(inputs, config)
        rescue
          e -> {:failed, id, Exception.message(e)}
        end

      failed ->
        failed
    end
  end
end
