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

  A workflow can be a macro, used as a tool by other workflows (see
  `IxpipeCore.Macro`): its optional `macro:` header declares its type and
  parameters, kept as written in `macro`.

  `parse/1` is `decode/1` (structure: YAML, tools, ids) then `validate/1` (a
  runnable DAG: ports, inputs, no cycles, nodes in topological order). An
  editor holds decoded drafts and validates before running.
  """

  defmodule Node do
    @moduledoc "One tool instance in a workflow."
    defstruct [:id, :tool, inputs: %{}, config: %{}, position: nil, macro: nil]

    @type t :: %__MODULE__{
            id: String.t(),
            tool: module(),
            inputs: %{String.t() => String.t()},
            config: map(),
            position: %{String.t() => number()} | nil,
            macro: IxpipeCore.Macro.t() | {:error, term()} | nil
          }
  end

  defstruct name: nil, nodes: [], macro: nil

  @type t :: %__MODULE__{name: String.t() | nil, nodes: [Node.t()], macro: map() | nil}

  @spec parse(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def parse(yaml, opts \\ []) do
    with {:ok, spec} <- decode(yaml, opts), do: validate(spec)
  end

  @doc """
  Parses a workflow without checking it is a runnable DAG.

  Macro nodes load the macro they name (`IxpipeCore.Macro.attach/3`) from a
  `path` relative to the folder of `:path`, the file `yaml` came from (the
  current directory without one). A macro that fails to load is kept as
  `{:error, reason}`, which `validate/1` reports.
  """
  @spec decode(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def decode(yaml, opts \\ []) do
    with {:ok, doc} <- read_yaml(yaml),
         {:ok, nodes} <- build_nodes(Map.get(doc, "nodes") || []) do
      spec = %__MODULE__{name: doc["name"], nodes: nodes, macro: header(doc["macro"])}

      case opts[:path] do
        nil ->
          {:ok, IxpipeCore.Macro.attach(spec, File.cwd!(), opts[:within] || [])}

        path ->
          path = Path.expand(path)
          {:ok, IxpipeCore.Macro.attach(spec, Path.dirname(path), [path | opts[:within] || []])}
      end
    end
  end

  # `macro:` with nothing under it still marks a macro.
  defp header(nil), do: nil
  defp header(header) when is_map(header), do: header
  defp header(_), do: %{}

  @doc "Checks `spec` is a runnable DAG and puts its nodes in topological order."
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{nodes: nodes} = spec) do
    with :ok <- check_macros(nodes),
         :ok <- check_inputs(nodes),
         {:ok, sorted} <- topo_sort(nodes),
         :ok <- check_config(sorted) do
      {:ok, %{spec | nodes: sorted}}
    end
  end

  @doc "The workflow as YAML that `decode/1` reads back unchanged."
  @spec to_yaml(t()) :: String.t()
  def to_yaml(%__MODULE__{} = spec) do
    name = if spec.name, do: ["name: ", flow(spec.name), "\n"], else: []
    name = if spec.macro, do: [name, "macro: ", flow(spec.macro), "\n"], else: name

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

  @doc """
  The node and output a wire reads: `"orders"` is `{"orders", nil}` (the
  node's first output), `"big.false"` is `{"big", "false"}`.
  """
  @spec source(String.t()) :: {String.t(), String.t() | nil}
  def source(ref) do
    case String.split(ref, ".", parts: 2) do
      [id, output] -> {id, output}
      [id] -> {id, nil}
    end
  end

  @doc "A one-line, human-readable description of a `parse/1` error."
  @spec format_error(term()) :: String.t()
  def format_error({:invalid_yaml, reason}), do: "invalid YAML: #{inspect(reason)}"
  def format_error({:unknown_tool, id, tool}), do: "#{id}: unknown tool #{inspect(tool)}"
  def format_error({:duplicate_id, id}), do: "duplicate node id #{id}"
  def format_error({:bad_id, id}), do: "#{id}: an id can't contain a dot"

  def format_error({:unknown_output, _id, ref} = error) do
    {from, output} = source(ref)
    "#{elem(error, 1)}: #{from} has no output #{output}"
  end

  def format_error({:unknown_input, id, from}), do: "#{id}: input #{from} is not a node"

  def format_error({:missing_config, id, keys}),
    do: "#{id}: needs config #{Enum.join(keys, ", ")}"

  def format_error({:cycle, ids}), do: "cycle: " <> Enum.join(ids, " -> ")

  def format_error({:macro, id, reason}), do: "#{id}: " <> IxpipeCore.Macro.format_error(reason)

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

        String.contains?(id, ".") ->
          {:halt, {:error, {:bad_id, id}}}

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
      expected = IxpipeCore.Tools.inputs(node)
      got = node.inputs |> Map.keys() |> Enum.sort()

      cond do
        Enum.sort(expected) != got ->
          {:error, {:bad_ports, node.id, expected: expected, got: got}}

        missing = Enum.find(Map.values(node.inputs), &(elem(source(&1), 0) not in ids)) ->
          {:error, {:unknown_input, node.id, missing}}

        bad = Enum.find(Map.values(node.inputs), &unknown_output?(&1, nodes)) ->
          {:error, {:unknown_output, node.id, bad}}

        true ->
          nil
      end
    end)
  end

  defp unknown_output?(ref, nodes) do
    case source(ref) do
      {_id, nil} ->
        false

      {id, output} ->
        output not in IxpipeCore.Tools.outputs(Enum.find(nodes, &(&1.id == id)))
    end
  end

  defp check_macros(nodes) do
    Enum.find_value(nodes, :ok, fn
      %Node{id: id, macro: {:error, reason}} -> {:error, {:macro, id, reason}}
      _ -> nil
    end)
  end

  defp check_config(nodes) do
    Enum.find_value(nodes, :ok, fn node ->
      case Enum.reject(IxpipeCore.Tools.required(node), &Map.has_key?(node.config, &1)) do
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
          Enum.find_value(node.inputs, fn {_port, ref} ->
            case :digraph.add_edge(graph, elem(source(ref), 0), node.id) do
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
