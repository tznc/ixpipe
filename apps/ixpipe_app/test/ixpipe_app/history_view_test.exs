defmodule IxpipeApp.HistoryViewTest do
  # Undo and redo of canvas edits, and zooming and panning the view.
  use ExUnit.Case, async: false
  alias Baguette.Test
  alias IxpipeCore.Spec

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-history-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "sales.yaml"), """
    name: sales
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
      - {id: sorted, tool: sort, position: {x: 300, y: 40}, inputs: {in: orders}, config: {by: [id]}}
    """)

    window = System.unique_integer([:positive])

    pid =
      start_supervised!(
        {IxpipeApp.MainView,
         window: window,
         theme: IxpipeApp.Theme,
         args: [dir: dir, path: Path.join(dir, "sales.yaml")]}
      )

    %{w: window, pid: pid}
  end

  defp spec(pid), do: :sys.get_state(pid).assigns.spec
  defp node(pid, id), do: Enum.find(spec(pid).nodes, &(&1.id == id))
  defp attrs(w, label), do: hd(Test.find_all(w, label))["a"]

  defp card_left(w, id) do
    [_, x] = Regex.run(~r/\bleft-\[(-?\d+)px\]/, attrs(w, id)["class"])
    String.to_integer(x)
  end

  test "undo and redo start disabled", %{w: w} do
    assert Map.has_key?(attrs(w, "Undo"), "disabled")
    assert Map.has_key?(attrs(w, "Redo"), "disabled")
  end

  test "undo and redo an added tool", %{w: w, pid: pid} do
    Test.click(w, "Add sample")
    assert node(pid, "sample_1")
    Test.click(w, "Undo")
    refute node(pid, "sample_1")
    Test.click(w, "Redo")
    assert node(pid, "sample_1")
  end

  test "undo a removal brings back the tool and its wires", %{w: w, pid: pid} do
    Test.click(w, "Remove orders")
    assert node(pid, "sorted").inputs == %{}
    Test.click(w, "Undo")
    assert node(pid, "orders")
    assert node(pid, "sorted").inputs == %{"in" => "orders"}
  end

  test "undo a move and a new wire", %{w: w, pid: pid} do
    Test.drag(w, "sorted", 40, 0)
    Test.click(w, "Add sort")
    Test.click(w, "Connect from sorted")
    Test.click(w, "Connect to sort_1 in")
    Test.click(w, "Undo")
    assert node(pid, "sort_1").inputs == %{}
    Test.click(w, "Undo")
    Test.click(w, "Undo")
    assert node(pid, "sorted").position == %{"x" => 300, "y" => 40}
  end

  test "typing into one setting is one step to undo", %{w: w, pid: pid} do
    Test.click(w, "Select sorted")
    Test.fill(w, "Sort by", "a")
    Test.fill(w, "Sort by", "amount")
    Test.click(w, "Undo")
    assert node(pid, "sorted").config == %{"by" => ["id"]}
  end

  test "a new edit after undo clears redo", %{w: w} do
    Test.click(w, "Add sample")
    Test.click(w, "Undo")
    Test.click(w, "Add unique")
    assert Map.has_key?(attrs(w, "Redo"), "disabled")
  end

  test "zoom scales positions, and drags move by canvas distance", %{w: w, pid: pid} do
    assert Test.text(w) =~ "100%"
    assert card_left(w, "sorted") == 300

    Test.click(w, "Zoom in")
    assert Test.text(w) =~ "125%"
    assert card_left(w, "sorted") == 375

    Test.drag(w, "sorted", 125, 0)
    assert node(pid, "sorted").position == %{"x" => 400, "y" => 40}
  end

  test "zoomed out below 75%, cards are compact", %{w: w} do
    Test.click(w, "Zoom out")
    Test.click(w, "Zoom out")
    assert Test.text(w) =~ "50%"
    assert Test.find_all(w, "Remove orders") == []
    assert Test.find_all(w, "Select orders") != []
  end

  test "panning moves the view, not the workflow", %{w: w, pid: pid} do
    Test.drag(w, "Canvas surface", 100, 50)
    assert card_left(w, "orders") == 140
    assert node(pid, "orders").position == %{"x" => 40, "y" => 40}

    Test.click(w, "Restore view")
    assert card_left(w, "orders") == 40
  end
end
