defmodule IxpipeCore.Edit do
  @moduledoc "Canvas edits to a (possibly incomplete) workflow."

  alias IxpipeCore.Spec

  @doc "Adds a `tool` node at `position`, with a fresh id such as `sort_1`."
  @spec add_node(Spec.t(), String.t(), map()) :: Spec.t()
  def add_node(spec, tool, position) do
    ids = MapSet.new(spec.nodes, & &1.id)

    id =
      Stream.iterate(1, &(&1 + 1)) |> Stream.map(&"#{tool}_#{&1}") |> Enum.find(&(&1 not in ids))

    node = %Spec.Node{id: id, tool: IxpipeCore.Tools.lookup(tool), position: position}
    %{spec | nodes: spec.nodes ++ [node]}
  end

  @doc """
  Moves node `id` by `dx`, `dy`, no further left or up than the canvas origin
  (where a node would be out of reach). A node without a position starts there.
  """
  @spec move_node(Spec.t(), String.t(), number(), number()) :: Spec.t()
  def move_node(spec, id, dx, dy) do
    update(spec, id, fn node ->
      %{"x" => x, "y" => y} = node.position || %{"x" => 0, "y" => 0}
      %{node | position: %{"x" => max(x + dx, 0), "y" => max(y + dy, 0)}}
    end)
  end

  @doc "Feeds `from` (a node, or `node.output`) into `port` of node `to`."
  @spec connect(Spec.t(), String.t(), String.t(), String.t()) :: Spec.t()
  def connect(spec, from, to, port),
    do: update(spec, to, &%{&1 | inputs: Map.put(&1.inputs, port, from)})

  @doc """
  Sets the setting `key` of node `id` from typed `text`, read with the
  tool's field for it (see `IxpipeCore.Config`). Empty text removes an
  optional setting.
  """
  @spec set_config(Spec.t(), String.t(), String.t(), String.t()) ::
          {:ok, Spec.t()} | {:error, String.t()}
  def set_config(spec, id, key, text) do
    with %Spec.Node{tool: tool} <- Enum.find(spec.nodes, &(&1.id == id)),
         %{} = field <- Enum.find(tool.fields(), &(&1.key == key)),
         {:ok, value} <- IxpipeCore.Config.parse(field, text) do
      config = fn config ->
        if value == nil, do: Map.delete(config, key), else: Map.put(config, key, value)
      end

      {:ok, update(spec, id, &%{&1 | config: config.(&1.config)})}
    else
      {:error, message} -> {:error, message}
      nil -> {:error, "Unknown setting"}
    end
  end

  @doc "Replaces node `id`'s config with `fun` of it, for editors that build values (Select's columns)."
  @spec update_config(Spec.t(), String.t(), (map() -> map())) :: Spec.t()
  def update_config(spec, id, fun), do: update(spec, id, &%{&1 | config: fun.(&1.config)})

  @doc "Removes node `id` and disconnects every input that read any of its outputs."
  @spec remove_node(Spec.t(), String.t()) :: Spec.t()
  def remove_node(spec, id) do
    nodes =
      for node <- spec.nodes, node.id != id do
        %{
          node
          | inputs:
              Map.reject(node.inputs, fn {_port, ref} -> elem(Spec.source(ref), 0) == id end)
        }
      end

    %{spec | nodes: nodes}
  end

  defp update(spec, id, fun),
    do: %{spec | nodes: Enum.map(spec.nodes, &if(&1.id == id, do: fun.(&1), else: &1))}
end
