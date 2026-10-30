defmodule IxpipeCore do
  @moduledoc "Runs workflows parsed by `IxpipeCore.Spec`."

  require Runic
  alias Runic.Workflow
  alias IxpipeCore.Spec

  @doc """
  Runs every node of `spec`, returning each node's output by node id. The
  first node to raise fails the run; nodes downstream of it do not run.
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
      |> Map.new(fn {id, [value | _]} -> {id, value} end)

    case Enum.find(Map.values(results), &match?({:failed, _, _}, &1)) do
      nil -> {:ok, results}
      {:failed, id, message} -> {:error, {:node_failed, id, message}}
    end
  end

  @doc "Compiles `spec` into a Runic workflow with one step per node."
  @spec to_runic(Spec.t()) :: Workflow.t()
  def to_runic(%Spec{} = spec) do
    Enum.reduce(spec.nodes, Runic.workflow(name: spec.name || "ixpipe"), fn node, wrk ->
      ports = node.tool.inputs()
      # A Runic join never fires on a repeated parent, so each parent feeds
      # the step once and `slots` maps every port to its parent's argument.
      parents = Enum.map(ports, &node.inputs[&1])
      unique = Enum.uniq(parents)
      slots = Enum.zip(ports, Enum.map(parents, fn p -> Enum.find_index(unique, &(&1 == p)) end))
      Workflow.add(wrk, step(node, slots, length(unique)), add_opts(unique))
    end)
  end

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
  def inputs(slots, args), do: Map.new(slots, fn {port, i} -> {port, Enum.at(args, i)} end)

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
