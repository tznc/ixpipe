defmodule IxpipeApp.MainViewTest do
  use ExUnit.Case, async: false
  alias Baguette.Test
  alias IxpipeCore.Spec

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "sales.yaml"), """
    name: sales
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
    """)

    %{dir: dir, window: System.unique_integer([:positive])}
  end

  defp start(%{dir: dir, window: window}, args \\ []) do
    start_supervised!(
      {IxpipeApp.MainView, window: window, theme: IxpipeApp.Theme, args: [dir: dir] ++ args}
    )

    window
  end

  defp saved(dir, file) do
    {:ok, spec} = dir |> Path.join(file) |> File.read!() |> Spec.decode()
    spec
  end

  test "home lists the workflows in the directory and opens one", ctx do
    w = start(ctx)
    assert Test.text(w) =~ "sales.yaml"

    Test.click(w, "Open sales.yaml")
    assert Test.text(w) =~ "orders"
    assert Test.text(w) =~ "Input CSV"

    Test.click(w, "Workflows")
    assert Test.text(w) =~ "sales.yaml"
  end

  test "a path opens straight onto the canvas", ctx do
    w = start(ctx, path: Path.join(ctx.dir, "sales.yaml"))
    assert Test.text(w) =~ "orders"
  end

  test "New workflow creates an empty file and opens it", ctx do
    w = start(ctx)
    Test.click(w, "New workflow")
    Test.click(w, "Save workflow")
    assert %Spec{nodes: []} = saved(ctx.dir, "untitled-1.yaml")
  end

  test "build, wire, move and save a workflow", ctx do
    w = start(ctx, path: Path.join(ctx.dir, "sales.yaml"))

    IxpipeApp.UI.add(w, "sort")
    assert Test.text(w) =~ "sort_1"

    Test.click(w, "Connect from orders")
    Test.click(w, "Connect to sort_1 in")
    Test.drag(w, "orders", 10, 5)
    Test.click(w, "Save workflow")

    spec = saved(ctx.dir, "sales.yaml")
    assert [orders, sort] = spec.nodes
    assert orders.position == %{"x" => 50, "y" => 45}
    assert sort.inputs == %{"in" => "orders"}
  end

  test "remove deletes a node and its edges", ctx do
    w = start(ctx, path: Path.join(ctx.dir, "sales.yaml"))
    IxpipeApp.UI.add(w, "sort")
    Test.click(w, "Connect from orders")
    Test.click(w, "Connect to sort_1 in")

    Test.click(w, "Remove orders")
    refute Test.text(w) =~ "orders"
    Test.click(w, "Save workflow")
    assert [%{id: "sort_1", inputs: %{}}] = saved(ctx.dir, "sales.yaml").nodes
  end

  test "Run reports row counts", ctx do
    w = start(ctx, path: Path.join(ctx.dir, "sales.yaml"))
    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "Run succeeded"
    assert Test.text(w) =~ "2 rows"
  end

  test "Run reports an incomplete workflow instead of running it", ctx do
    w = start(ctx, path: Path.join(ctx.dir, "sales.yaml"))
    IxpipeApp.UI.add(w, "sort")
    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "sort_1: expects inputs [in], got []"
  end

  test "Run reports the failing node", ctx do
    File.write!(
      Path.join(ctx.dir, "bad.yaml"),
      "nodes: [{id: orders, tool: input_csv, config: {path: /nope.csv}}]"
    )

    w = start(ctx, path: Path.join(ctx.dir, "bad.yaml"))
    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "orders failed"
  end

  test "a file that does not load says why", ctx do
    File.write!(Path.join(ctx.dir, "broken.yaml"), "nodes: [{id: a, tool: nope}]")
    w = start(ctx)
    Test.click(w, "Open broken.yaml")
    assert Test.text(w) =~ "unknown tool"
  end

  test "every colour class resolves to a theme token, on both screens", ctx do
    w = start(ctx)
    assert IxpipeApp.UI.unresolved_colours(w) == []
    Test.click(w, "Open sales.yaml")
    IxpipeApp.UI.add(w, "sort")
    Test.click(w, "Connect from orders")
    Test.click(w, "Connect to sort_1 in")
    assert IxpipeApp.UI.unresolved_colours(w) == []
  end

  test "the canvas scrolls to every node: its surface covers the furthest one", ctx do
    w = start(ctx, path: Path.join(ctx.dir, "sales.yaml"))
    IxpipeApp.UI.add(w, "sort")
    Test.drag(w, "sort_1", 900, 700)

    [surface] = IxpipeApp.UI.find(w, "Canvas surface")
    [scroller] = IxpipeApp.UI.find(w, "Canvas")
    assert scroller["a"]["class"] =~ "overflow-scroll"

    [_, width] = Regex.run(~r/\bw-\[(\d+)px\]/, surface["a"]["class"])
    [_, height] = Regex.run(~r/\bh-\[(\d+)px\]/, surface["a"]["class"])
    # sort_1 now sits at 970, 770; the surface reaches past its far edge.
    assert String.to_integer(width) >= 970 + 200
    assert String.to_integer(height) >= 770 + 100
  end
end
