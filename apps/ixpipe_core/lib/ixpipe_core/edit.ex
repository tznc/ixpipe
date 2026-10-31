defmodule IxpipeCore.Edit do
  @moduledoc "Canvas edits to a (possibly incomplete) workflow."

  alias IxpipeCore.Spec

  @doc """
  Adds a `tool` node at `position`, with a fresh id such as `sort_1`, inside
  `container` when given.
  """
  @spec add_node(Spec.t(), String.t(), map(), String.t() | nil) :: Spec.t()
  def add_node(spec, tool, position, container \\ nil) do
    id = fresh_id(spec, tool)
    node = %Spec.Node{id: id, tool: IxpipeCore.Tools.lookup(tool), position: position}
    contain(%{spec | nodes: spec.nodes ++ [node]}, id, container)
  end

  @doc """
  Adds a container at `position` holding the tools `ids` (taking them out of
  any other), with a fresh id (`container_1`) and title ("Container 1").
  """
  @spec add_container(Spec.t(), map(), [String.t()]) :: Spec.t()
  def add_container(spec, position, ids) do
    id = fresh_id(spec, "container")
    title = "Container " <> String.replace_prefix(id, "container_", "")
    container = %Spec.Container{id: id, title: title, position: position}
    spec = %{spec | containers: spec.containers ++ [container]}
    Enum.reduce(ids, spec, &contain(&2, &1, id))
  end

  @doc "Adds an empty comment at `position`, with a fresh id such as `comment_1`."
  @spec add_comment(Spec.t(), map()) :: Spec.t()
  def add_comment(spec, position) do
    comment = %Spec.Comment{id: fresh_id(spec, "comment"), position: position}
    %{spec | comments: spec.comments ++ [comment]}
  end

  @doc "Puts tool `id` in `container`, out of any other; `nil` takes it out."
  @spec contain(Spec.t(), String.t(), String.t() | nil) :: Spec.t()
  def contain(spec, id, container) do
    containers =
      for c <- spec.containers do
        nodes = List.delete(c.nodes, id)
        %{c | nodes: if(c.id == container, do: nodes ++ [id], else: nodes)}
      end

    %{spec | containers: containers}
  end

  @doc """
  Moves a tool, a container (with its tools) or a comment by `dx`, `dy`,
  never past the canvas origin: a container stops where its first tool would
  leave the canvas.
  """
  @spec move(Spec.t(), String.t(), number(), number()) :: Spec.t()
  def move(spec, id, dx, dy) do
    case find(spec, id) do
      %Spec.Container{} = c ->
        held = Enum.filter(spec.nodes, &(&1.id in c.nodes))
        {dx, dy} = Enum.reduce([c | held], {dx, dy}, &clamp/2)
        spec = Enum.reduce(c.nodes, spec, &move_node(&2, &1, dx, dy))
        put(spec, :containers, id, &%{&1 | position: shift(&1.position, dx, dy)})

      %Spec.Comment{} ->
        put(spec, :comments, id, &%{&1 | position: shift(&1.position, dx, dy)})

      _ ->
        move_node(spec, id, dx, dy)
    end
  end

  # The largest move toward the origin that keeps `item` on the canvas.
  defp clamp(item, {dx, dy}) do
    %{"x" => x, "y" => y} = item.position || %{"x" => 0, "y" => 0}
    {max(dx, -x), max(dy, -y)}
  end

  defp shift(%{"x" => x, "y" => y}, dx, dy), do: %{"x" => max(x + dx, 0), "y" => max(y + dy, 0)}

  @doc "Titles a container or writes a comment's text."
  @spec set_text(Spec.t(), String.t(), String.t()) :: Spec.t()
  def set_text(spec, id, text) do
    spec
    |> put(:containers, id, &%{&1 | title: text})
    |> put(:comments, id, &%{&1 | text: text})
  end

  @doc "Collapses container `id` to its title bar, or expands it."
  @spec set_collapsed(Spec.t(), String.t(), boolean()) :: Spec.t()
  def set_collapsed(spec, id, collapsed),
    do: put(spec, :containers, id, &%{&1 | collapsed: collapsed})

  @doc "Disables (or enables) a tool or a container: a run skips what is disabled."
  @spec set_disabled(Spec.t(), String.t(), boolean()) :: Spec.t()
  def set_disabled(spec, id, disabled) do
    spec
    |> update(id, &%{&1 | disabled: disabled})
    |> put(:containers, id, &%{&1 | disabled: disabled})
  end

  @doc "Sets the note shown under tool `id`; blank text removes it."
  @spec set_annotation(Spec.t(), String.t(), String.t()) :: Spec.t()
  def set_annotation(spec, id, text) do
    text = String.trim(text)
    update(spec, id, &%{&1 | annotation: if(text != "", do: text)})
  end

  @doc """
  Removes a tool (see `remove_node/2`), a comment, or a container: by
  default its tools stay on the canvas; `with_tools: true` removes them too.
  """
  @spec remove(Spec.t(), String.t(), keyword()) :: Spec.t()
  def remove(spec, id, opts \\ []) do
    case find(spec, id) do
      %Spec.Container{nodes: held} ->
        spec = %{spec | containers: Enum.reject(spec.containers, &(&1.id == id))}
        if opts[:with_tools], do: Enum.reduce(held, spec, &remove_node(&2, &1)), else: spec

      %Spec.Comment{} ->
        %{spec | comments: Enum.reject(spec.comments, &(&1.id == id))}

      _ ->
        remove_node(spec, id)
    end
  end

  @doc "The tool, container or comment with `id`, or nil."
  @spec find(Spec.t(), String.t()) :: Spec.Node.t() | Spec.Container.t() | Spec.Comment.t() | nil
  def find(spec, id),
    do: Enum.find(spec.nodes ++ spec.containers ++ spec.comments, &(&1.id == id))

  # A fresh id for `prefix`, unique across tools, containers and comments.
  defp fresh_id(spec, prefix) do
    ids = MapSet.new(spec.nodes ++ spec.containers ++ spec.comments, & &1.id)
    Stream.iterate(1, &(&1 + 1)) |> Stream.map(&"#{prefix}_#{&1}") |> Enum.find(&(&1 not in ids))
  end

  defp put(spec, key, id, fun),
    do:
      Map.update!(spec, key, fn items ->
        Enum.map(items, &if(&1.id == id, do: fun.(&1), else: &1))
      end)

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

  @doc """
  Removes node `id`, disconnects every input that read any of its outputs and
  takes it out of its container.
  """
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

    contain(%{spec | nodes: nodes}, id, nil)
  end

  defp update(spec, id, fun),
    do: %{spec | nodes: Enum.map(spec.nodes, &if(&1.id == id, do: fun.(&1), else: &1))}
end
