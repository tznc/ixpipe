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

  @doc "Moves node `id` by `dx`, `dy`. A node without a position starts at the origin."
  @spec move_node(Spec.t(), String.t(), number(), number()) :: Spec.t()
  def move_node(spec, id, dx, dy) do
    update(spec, id, fn node ->
      %{"x" => x, "y" => y} = node.position || %{"x" => 0, "y" => 0}
      %{node | position: %{"x" => x + dx, "y" => y + dy}}
    end)
  end

  @doc "Feeds node `from` into `port` of node `to`."
  @spec connect(Spec.t(), String.t(), String.t(), String.t()) :: Spec.t()
  def connect(spec, from, to, port),
    do: update(spec, to, &%{&1 | inputs: Map.put(&1.inputs, port, from)})

  @doc "Removes node `id` and disconnects every input that read from it."
  @spec remove_node(Spec.t(), String.t()) :: Spec.t()
  def remove_node(spec, id) do
    nodes =
      for node <- spec.nodes, node.id != id do
        %{node | inputs: Map.reject(node.inputs, fn {_port, from} -> from == id end)}
      end

    %{spec | nodes: nodes}
  end

  defp update(spec, id, fun),
    do: %{spec | nodes: Enum.map(spec.nodes, &if(&1.id == id, do: fun.(&1), else: &1))}
end
