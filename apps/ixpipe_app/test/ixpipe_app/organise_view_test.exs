defmodule IxpipeApp.OrganiseViewTest do
  # Organising the canvas: containers, comments, annotations and disabled
  # tools, from the ribbon's Organise group and the properties panel.
  use ExUnit.Case, async: false
  alias Baguette.Test
  alias IxpipeApp.UI
  alias IxpipeCore.Spec

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-organise-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "sales.yaml"), """
    name: sales
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 60}, config: {path: #{@fixtures}/orders.csv}}
      - {id: sorted, tool: sort, position: {x: 300, y: 60}, inputs: {in: orders}, config: {by: [amount]}}
      - {id: top, tool: sample, position: {x: 560, y: 60}, inputs: {in: sorted}, config: {n: 2}}
    """)

    window = System.unique_integer([:positive])

    pid =
      start_supervised!(
        {IxpipeApp.MainView,
         window: window,
         theme: IxpipeApp.Theme,
         args: [dir: dir, path: Path.join(dir, "sales.yaml")]}
      )

    %{w: window, pid: pid, dir: dir}
  end

  defp spec(pid), do: :sys.get_state(pid).assigns.spec
  defp item(pid, id), do: IxpipeCore.Edit.find(spec(pid), id)
  defp attrs(w, label), do: hd(UI.find(w, label))["a"]

  defp saved(dir) do
    {:ok, spec} = dir |> Path.join("sales.yaml") |> File.read!() |> Spec.decode()
    spec
  end

  test "Home has an Organise group with Container and Comment, with icons", %{w: w} do
    assert attrs(w, "Organise")["role"] == "group"
    assert Test.icons(w, "Add container") == ["square-dashed"]
    assert Test.icons(w, "Add comment") == ["message-square-text"]
  end

  test "a container made with a tool selected holds it, and moves it", %{w: w, pid: pid} do
    Test.click(w, "Select sorted")
    Test.click(w, "Add container")
    assert %Spec.Container{nodes: ["sorted"], title: "Container 1"} = item(pid, "container_1")
    assert Test.text(w) =~ "Container 1"

    Test.drag(w, "container_1", 20, 10)
    assert item(pid, "sorted").position == %{"x" => 320, "y" => 70}
    assert item(pid, "orders").position == %{"x" => 40, "y" => 60}

    Test.click(w, "Undo")
    assert item(pid, "sorted").position == %{"x" => 300, "y" => 60}
  end

  test "a tool added while a container is selected is created inside it", %{w: w, pid: pid} do
    Test.click(w, "Add container")
    assert item(pid, "container_1").nodes == []
    UI.add(w, "filter")
    assert item(pid, "container_1").nodes == ["filter_1"]
  end

  test "a tool joins or leaves a container from its properties", %{w: w, pid: pid} do
    Test.click(w, "Add container")
    Test.click(w, "Select orders")
    Test.click(w, "Put in Container 1")
    assert item(pid, "container_1").nodes == ["orders"]
    Test.click(w, "Take out of container")
    assert item(pid, "container_1").nodes == []
  end

  test "a container is titled, collapsed and expanded", %{w: w, pid: pid} do
    Test.click(w, "Select sorted")
    Test.click(w, "Add container")
    Test.fill(w, "Title", "Prepare")
    assert item(pid, "container_1").title == "Prepare"

    Test.click(w, "Collapse container_1")
    assert item(pid, "container_1").collapsed
    # Its tools are hidden; the box stays, with its title.
    assert UI.find(w, "sorted") == []
    assert Test.text(w) =~ "Prepare"
    Test.click(w, "Expand container_1")
    assert UI.find(w, "sorted") != []
  end

  test "a collapsed container draws its wires to its edge", %{w: w} do
    Test.click(w, "Select sorted")
    Test.click(w, "Add container")
    assert [_, _] = lines(w)
    Test.click(w, "Collapse container_1")
    # orders -> box and box -> top: still two wires, ending at the box's edges.
    assert [into, out_of] = lines(w)
    box = attrs(w, "container_1")["class"]
    [_, left] = Regex.run(~r/\bleft-\[(\d+)px\]/, box)
    [_, width] = Regex.run(~r/\bw-\[(\d+)px\]/, box)
    assert into["a"]["x2"] == left
    assert out_of["a"]["x1"] == to_string(String.to_integer(left) + String.to_integer(width))
  end

  test "a disabled tool shows at 40% and is skipped with what follows", %{w: w, pid: pid} do
    Test.click(w, "Select sorted")
    Test.click(w, "Disable tool")
    assert item(pid, "sorted").disabled
    assert attrs(w, "sorted")["class"] =~ "opacity-40"
    refute attrs(w, "orders")["class"] =~ "opacity-40"

    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "Run succeeded"
    assert Test.text(w) =~ "2 tools skipped"
    # A badge on each skipped card.
    assert length(String.split(Test.text(w), "Skipped")) == 3

    Test.click(w, "Enable tool")
    refute item(pid, "sorted").disabled
  end

  test "a disabled container skips its tools", %{w: w} do
    Test.click(w, "Select orders")
    Test.click(w, "Add container")
    Test.click(w, "Disable container")
    assert attrs(w, "container_1")["class"] =~ "opacity-40"
    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "3 tools skipped"
  end

  test "remove a container, keeping or removing its tools", %{w: w, pid: pid} do
    Test.click(w, "Select sorted")
    Test.click(w, "Add container")
    Test.click(w, "Remove container")
    assert spec(pid).containers == []
    assert item(pid, "sorted")

    Test.click(w, "Undo")
    Test.click(w, "Select container_1")
    Test.click(w, "Remove container and tools")
    refute item(pid, "sorted")
  end

  test "comments are added, written, moved and removed", %{w: w, pid: pid} do
    Test.click(w, "Add comment")
    Test.fill(w, "Comment", "Orders arrive daily")
    assert Test.text(w) =~ "Orders arrive daily"
    Test.drag(w, "comment_1", 10, 10)
    assert %{text: "Orders arrive daily"} = item(pid, "comment_1")
    Test.click(w, "Remove comment")
    assert spec(pid).comments == []
  end

  test "an annotation shows under its tool, and can summarise its settings", %{w: w, pid: pid} do
    Test.click(w, "Select top")
    Test.fill(w, "Annotation", "Best two")
    assert Test.text(w) =~ "Best two"
    Test.click(w, "Summarise settings")
    assert item(pid, "top").annotation == "Rows: 2"
  end

  test "everything persists to YAML", %{w: w, dir: dir} do
    Test.click(w, "Select sorted")
    Test.click(w, "Disable tool")
    Test.fill(w, "Annotation", "By amount")
    Test.click(w, "Add container")
    Test.click(w, "Collapse container_1")
    Test.click(w, "Add comment")
    Test.fill(w, "Comment", "Hi")
    Test.click(w, "Save workflow")

    spec = saved(dir)
    assert [%{nodes: ["sorted"], collapsed: true}] = spec.containers
    assert [%{text: "Hi"}] = spec.comments

    assert %{disabled: true, annotation: "By amount"} =
             Enum.find(spec.nodes, &(&1.id == "sorted"))
  end

  defp lines(w) do
    elements = fn
      %{"c" => children} = el, f -> [el | Enum.flat_map(children, &f.(&1, f))]
      _, _ -> []
    end

    for %{"t" => "line"} = el <- elements.(Test.tree(w), elements), do: el
  end
end
