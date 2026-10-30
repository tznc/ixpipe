defmodule IxpipeCore.Spec do
  @moduledoc """
  A workflow parsed from YAML and validated into a DAG.

      name: sales
      nodes:
        - id: orders
          tool: input_csv
          config: {path: orders.csv}
        - id: sorted
          tool: sort
          inputs: {in: orders}
          config: {by: [amount]}

  Each node names a tool, maps the tool's input ports to upstream node ids and
  carries the tool's config and, optionally, its canvas `position`.

  `parse/1` is `decode/1` (structure: YAML, tools, ids) then `validate/1` (a
  runnable DAG: ports, inputs, no cycles, nodes in topological order). An
  editor holds decoded drafts and validates before running.
  """

  defmodule Node do
    @moduledoc "One tool instance in a workflow."
    defstruct [:id, :tool, inputs: %{}, config: %{}, position: nil]

    @type t :: %__MODULE__{
            id: String.t(),
            tool: module(),
            inputs: %{String.t() => String.t()},
            config: map(),
            position: %{String.t() => number()} | nil
          }
  end

  defstruct name: nil, nodes: []

  @type t :: %__MODULE__{name: String.t() | nil, nodes: [Node.t()]}

  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(yaml) do
    with {:ok, spec} <- decode(yaml), do: validate(spec)
  end

  @doc "Parses a workflow without checking it is a runnable DAG."
  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(yaml) do
    with {:ok, doc} <- read_yaml(yaml),
         {:ok, nodes} <- build_nodes(Map.get(doc, "nodes") || []) do
      {:ok, %__MODULE__{name: doc["name"], nodes: nodes}}
    end
  end

  @doc "Checks `spec` is a runnable DAG and puts its nodes in topological order."
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{nodes: nodes} = spec) do
    with :ok <- check_inputs(nodes),
         {:ok, sorted} <- topo_sort(nodes),
         :ok <- check_config(sorted) do
      {:ok, %{spec | nodes: sorted}}
    end
  end

  @doc "The workflow as YAML that `decode/1` reads back unchanged."
  @spec to_yaml(t()) :: String.t()
  def to_yaml(%__MODULE__{} = spec) do
    name = if spec.name, do: ["name: ", flow(spec.name), "\n"], else: []

    nodes =
      for node <- spec.nodes do
        fields =
          [
            {"id", node.id},
            {"tool", IxpipeCore.Tools.name(node.tool)},
            {"position", node.position},
            {"inputs", if(node.inputs != %{}, do: node.inputs)},
            {"config", if(node.config != %{}, do: node.config)}
          ]
          |> Enum.reject(fn {_, value} -> is_nil(value) end)
          |> Enum.map(fn {key, value} -> [key, ": ", flow(value)] end)

        ["  - ", Enum.intersperse(fields, "\n    "), "\n"]
      end

    IO.iodata_to_binary([name, "nodes:", if(nodes == [], do: " []\n", else: ["\n", nodes])])
  end

  # Flow-style YAML. Strings are JSON-quoted, which YAML reads verbatim.
  defp flow(map) when is_map(map) do
    pairs = map |> Enum.sort() |> Enum.map(fn {k, v} -> [flow(to_string(k)), ": ", flow(v)] end)
    ["{", Enum.intersperse(pairs, ", "), "}"]
  end

  defp flow(list) when is_list(list),
    do: ["[", Enum.intersperse(Enum.map(list, &flow/1), ", "), "]"]

  defp flow(nil), do: "null"
  defp flow(value) when is_binary(value), do: Jason.encode!(value)
  defp flow(value), do: to_string(value)

  @doc "A one-line, human-readable description of a `parse/1` error."
  @spec format_error(term()) :: String.t()
  def format_error({:invalid_yaml, reason}), do: "invalid YAML: #{inspect(reason)}"
  def format_error({:unknown_tool, id, tool}), do: "#{id}: unknown tool #{inspect(tool)}"
  def format_error({:duplicate_id, id}), do: "duplicate node id #{id}"
  def format_error({:unknown_input, id, from}), do: "#{id}: input #{from} is not a node"

  def format_error({:missing_config, id, keys}),
    do: "#{id}: needs config #{Enum.join(keys, ", ")}"

  def format_error({:cycle, ids}), do: "cycle: " <> Enum.join(ids, " -> ")

  def format_error({:bad_ports, id, expected: expected, got: got}),
    do: "#{id}: expects inputs [#{Enum.join(expected, ", ")}], got [#{Enum.join(got, ", ")}]"

  defp read_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, doc} when is_map(doc) -> {:ok, doc}
      {:ok, other} -> {:error, {:invalid_yaml, other}}
      {:error, reason} -> {:error, {:invalid_yaml, reason}}
    end
  end

  defp build_nodes(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn node, {:ok, acc} ->
      id = to_string(node["id"])

      cond do
        Enum.any?(acc, &(&1.id == id)) ->
          {:halt, {:error, {:duplicate_id, id}}}

        tool = IxpipeCore.Tools.lookup(node["tool"]) ->
          inputs = Map.new(node["inputs"] || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)

          node = %Node{
            id: id,
            tool: tool,
            inputs: inputs,
            config: node["config"] || %{},
            position: node["position"]
          }

          {:cont, {:ok, [node | acc]}}

        true ->
          {:halt, {:error, {:unknown_tool, id, node["tool"]}}}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      error -> error
    end
  end

  defp check_inputs(nodes) do
    ids = MapSet.new(nodes, & &1.id)

    Enum.find_value(nodes, :ok, fn node ->
      expected = node.tool.inputs()
      got = node.inputs |> Map.keys() |> Enum.sort()

      cond do
        Enum.sort(expected) != got ->
          {:error, {:bad_ports, node.id, expected: expected, got: got}}

        missing = Enum.find(Map.values(node.inputs), &(&1 not in ids)) ->
          {:error, {:unknown_input, node.id, missing}}

        true ->
          nil
      end
    end)
  end

  defp check_config(nodes) do
    Enum.find_value(nodes, :ok, fn node ->
      case Enum.reject(IxpipeCore.Tools.required(node.tool), &Map.has_key?(node.config, &1)) do
        [] -> nil
        missing -> {:error, {:missing_config, node.id, missing}}
      end
    end)
  end

  defp topo_sort(nodes) do
    graph = :digraph.new([:acyclic])

    try do
      Enum.each(nodes, &:digraph.add_vertex(graph, &1.id))

      cycle =
        Enum.find_value(nodes, fn node ->
          Enum.find_value(node.inputs, fn {_port, from} ->
            case :digraph.add_edge(graph, from, node.id) do
              {:error, {:bad_edge, path}} -> Enum.uniq(path)
              _ -> nil
            end
          end)
        end)

      if cycle do
        {:error, {:cycle, cycle}}
      else
        by_id = Map.new(nodes, &{&1.id, &1})
        {:ok, graph |> :digraph_utils.topsort() |> Enum.map(&by_id[&1])}
      end
    after
      :digraph.delete(graph)
    end
  end
end
