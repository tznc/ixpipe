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
  carries the tool's config and, optionally, its canvas `position`, an
  `annotation` shown under it and `disabled: true`.

  A workflow can also be organised on the canvas, with optional top-level
  keys (absent in older workflows, which load unchanged):

      containers:
        - {id: prep, title: Prepare, position: {x: 20, y: 0}, nodes: [orders, sorted],
           collapsed: true, disabled: true}
      comments:
        - {id: note, text: Orders arrive daily, position: {x: 40, y: 400}}

  A container holds tools (each in at most one); a disabled one disables
  them. A disabled tool, and everything downstream of it, is skipped by a
  run (`skipped/1`). Ids are unique across tools, containers and comments.

  `parse/1` is `decode/1` (structure: YAML, tools, ids) then `validate/1` (a
  runnable DAG: ports, inputs, no cycles, nodes in topological order). An
  editor holds decoded drafts and validates before running.
  """

  defmodule Node do
    @moduledoc "One tool instance in a workflow."
    defstruct [
      :id,
      :tool,
      inputs: %{},
      config: %{},
      position: nil,
      annotation: nil,
      disabled: false
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            tool: module(),
            inputs: %{String.t() => String.t()},
            config: map(),
            position: %{String.t() => number()} | nil,
            annotation: String.t() | nil,
            disabled: boolean()
          }
  end

  defmodule Container do
    @moduledoc "A titled box on the canvas holding tools (by id)."
    defstruct [
      :id,
      title: "",
      position: %{"x" => 0, "y" => 0},
      nodes: [],
      collapsed: false,
      disabled: false
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            title: String.t(),
            position: %{String.t() => number()},
            nodes: [String.t()],
            collapsed: boolean(),
            disabled: boolean()
          }
  end

  defmodule Comment do
    @moduledoc "Free text on the canvas."
    defstruct [:id, text: "", position: %{"x" => 0, "y" => 0}]

    @type t :: %__MODULE__{id: String.t(), text: String.t(), position: %{String.t() => number()}}
  end

  defstruct name: nil, nodes: [], containers: [], comments: []

  @type t :: %__MODULE__{
          name: String.t() | nil,
          nodes: [Node.t()],
          containers: [Container.t()],
          comments: [Comment.t()]
        }

  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(yaml) do
    with {:ok, spec} <- decode(yaml), do: validate(spec)
  end

  @doc "Parses a workflow without checking it is a runnable DAG."
  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(yaml) do
    with {:ok, doc} <- read_yaml(yaml),
         {:ok, nodes} <- build_nodes(Map.get(doc, "nodes") || []),
         containers = Enum.map(doc["containers"] || [], &build_container/1),
         comments = Enum.map(doc["comments"] || [], &build_comment/1),
         :ok <- check_ids(nodes, containers, comments),
         :ok <- check_members(nodes, containers) do
      {:ok,
       %__MODULE__{name: doc["name"], nodes: nodes, containers: containers, comments: comments}}
    end
  end

  @doc """
  The tools a run skips, in workflow order: each disabled tool, each tool in
  a disabled container, and everything downstream of them.
  """
  @spec skipped(t()) :: [String.t()]
  def skipped(%__MODULE__{} = spec) do
    off =
      MapSet.new(
        for(node <- spec.nodes, node.disabled, do: node.id) ++
          for(c <- spec.containers, c.disabled, id <- c.nodes, do: id)
      )

    set = downstream(spec.nodes, off)
    for node <- spec.nodes, node.id in set, do: node.id
  end

  # Grows `set` with every node reading from it, until nothing changes.
  defp downstream(nodes, set) do
    grown =
      for node <- nodes,
          Enum.any?(node.inputs, fn {_port, ref} -> elem(source(ref), 0) in set end),
          into: set,
          do: node.id

    if MapSet.size(grown) == MapSet.size(set), do: set, else: downstream(nodes, grown)
  end

  @doc "Checks `spec` is a runnable DAG and puts its nodes in topological order."
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{nodes: nodes} = spec) do
    with :ok <- check_inputs(nodes),
         {:ok, sorted} <- topo_sort(nodes),
         skipped = skipped(spec),
         :ok <- check_config(Enum.reject(sorted, &(&1.id in skipped))) do
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
            {"config", if(node.config != %{}, do: node.config)},
            {"annotation", node.annotation},
            {"disabled", if(node.disabled, do: true)}
          ]

        item(fields)
      end

    containers =
      for c <- spec.containers do
        item([
          {"id", c.id},
          {"title", c.title},
          {"position", c.position},
          {"nodes", c.nodes},
          {"collapsed", if(c.collapsed, do: true)},
          {"disabled", if(c.disabled, do: true)}
        ])
      end

    comments =
      for c <- spec.comments, do: item([{"id", c.id}, {"text", c.text}, {"position", c.position}])

    IO.iodata_to_binary([
      name,
      "nodes:",
      if(nodes == [], do: " []\n", else: ["\n", nodes]),
      if(containers != [], do: ["containers:\n", containers], else: []),
      if(comments != [], do: ["comments:\n", comments], else: [])
    ])
  end

  # One list item: its non-nil fields, flow-style.
  defp item(fields) do
    fields =
      fields
      |> Enum.reject(fn {_, value} -> is_nil(value) end)
      |> Enum.map(fn {key, value} -> [key, ": ", flow(value)] end)

    ["  - ", Enum.intersperse(fields, "\n    "), "\n"]
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

  def format_error({:unknown_member, container, id}),
    do: "#{container}: holds #{id}, which is not a tool"

  def format_error({:duplicate_member, container, id}),
    do: "#{container}: holds #{id}, which is already in another container"

  def format_error({:unknown_output, _id, ref} = error) do
    {from, output} = source(ref)
    "#{elem(error, 1)}: #{from} has no output #{output}"
  end

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

        String.contains?(id, ".") ->
          {:halt, {:error, {:bad_id, id}}}

        tool = IxpipeCore.Tools.lookup(node["tool"]) ->
          inputs = Map.new(node["inputs"] || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)

          node = %Node{
            id: id,
            tool: tool,
            inputs: inputs,
            config: node["config"] || %{},
            position: node["position"],
            annotation: text(node["annotation"]),
            disabled: node["disabled"] == true
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

  @origin %{"x" => 0, "y" => 0}

  defp build_container(raw) do
    %Container{
      id: to_string(raw["id"]),
      title: text(raw["title"]) || "",
      position: raw["position"] || @origin,
      nodes: Enum.map(raw["nodes"] || [], &to_string/1),
      collapsed: raw["collapsed"] == true,
      disabled: raw["disabled"] == true
    }
  end

  defp build_comment(raw),
    do: %Comment{
      id: to_string(raw["id"]),
      text: text(raw["text"]) || "",
      position: raw["position"] || @origin
    }

  defp text(nil), do: nil
  defp text(value), do: to_string(value)

  defp check_ids(nodes, containers, comments) do
    ids = Enum.map(nodes ++ containers ++ comments, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] -> :ok
      [id | _] -> {:error, {:duplicate_id, id}}
    end
  end

  defp check_members(nodes, containers) do
    ids = MapSet.new(nodes, & &1.id)

    Enum.reduce_while(containers, {:ok, MapSet.new()}, fn c, {:ok, seen} ->
      cond do
        missing = Enum.find(c.nodes, &(&1 not in ids)) ->
          {:halt, {:error, {:unknown_member, c.id, missing}}}

        twice = Enum.find(c.nodes, &(&1 in seen)) ->
          {:halt, {:error, {:duplicate_member, c.id, twice}}}

        true ->
          {:cont, {:ok, MapSet.union(seen, MapSet.new(c.nodes))}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
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
        output not in IxpipeCore.Tools.outputs(Enum.find(nodes, &(&1.id == id)).tool)
    end
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
