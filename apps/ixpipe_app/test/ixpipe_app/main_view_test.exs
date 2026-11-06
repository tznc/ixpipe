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
    assert Test.text(w) =~ "Failed at orders."
    assert Test.text(w) =~ "The file /nope.csv doesn't exist. Choose a file that does."
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

  # The first free spot, so a new tool's card and connectors are never
  # under another card (where a click would land on that card instead).
  test "a new tool lands clear of every card already on the canvas", ctx do
    File.write!(Path.join(ctx.dir, "busy.yaml"), """
    name: busy
    nodes:
      - {id: a, tool: input_csv, position: {x: 20, y: 30}, config: {path: x.csv}}
      - {id: b, tool: input_csv, position: {x: 20, y: 190}, config: {path: x.csv}}
      - {id: c, tool: sort, position: {x: 240, y: 110}, inputs: {in: a}, config: {by: [id]}}
      - {id: d, tool: sort, position: {x: 460, y: 110}, inputs: {in: c}, config: {by: [id]}}
      - {id: e, tool: sort, position: {x: 680, y: 30}, inputs: {in: d}, config: {by: [id]}}
      - {id: f, tool: sort, position: {x: 680, y: 190}, inputs: {in: d}, config: {by: [id]}}
    """)

    w = ctx.window

    pid =
      start_supervised!(
        {IxpipeApp.MainView,
         window: w,
         theme: IxpipeApp.Theme,
         args: [dir: ctx.dir, path: Path.join(ctx.dir, "busy.yaml")]}
      )

    for _ <- 1..3, do: IxpipeApp.UI.add(w, "select")

    nodes = :sys.get_state(pid).assigns.spec.nodes
    {added, existing} = Enum.split_with(nodes, &String.starts_with?(&1.id, "select_"))

    # A card is 200 wide; about 130 tall with only an Out row (an input),
    # 165 with In and Out rows.
    box = fn %{position: %{"x" => x, "y" => y}} = node ->
      {x, y, 200, if(node.tool.inputs() == [], do: 130, else: 165)}
    end

    apart? = fn {x1, y1, w1, h1}, {x2, y2, w2, h2} ->
      x1 + w1 <= x2 or x2 + w2 <= x1 or y1 + h1 <= y2 or y2 + h2 <= y1
    end

    for new <- added, old <- existing ++ (added -- [new]) do
      assert apart?.(box.(new), box.(old)), "#{new.id} overlaps #{old.id}"
    end
  end

  # With no room in view, the canvas pans to show the new tool, so it can be
  # wired straight away (it is never added out of sight).
  test "a new tool placed out of view pans the canvas to it", ctx do
    File.write!(Path.join(ctx.dir, "full.yaml"), """
    name: full
    nodes:
      - {id: a, tool: input_csv, position: {x: 20, y: 30}, config: {path: x.csv}}
      - {id: b, tool: input_csv, position: {x: 20, y: 190}, config: {path: x.csv}}
      - {id: c, tool: sort, position: {x: 240, y: 110}, inputs: {in: a}, config: {by: [id]}}
      - {id: d, tool: sort, position: {x: 460, y: 110}, inputs: {in: c}, config: {by: [id]}}
      - {id: e, tool: sort, position: {x: 680, y: 30}, inputs: {in: d}, config: {by: [id]}}
      - {id: f, tool: sort, position: {x: 680, y: 190}, inputs: {in: d}, config: {by: [id]}}
    """)

    w = ctx.window

    start_supervised!(
      {IxpipeApp.MainView,
       window: w,
       theme: IxpipeApp.Theme,
       args: [dir: ctx.dir, path: Path.join(ctx.dir, "full.yaml")]}
    )

    Test.resize(w, 1200, 800)
    IxpipeApp.UI.add(w, "select")

    [_, left, top] =
      Regex.run(
        ~r/\bleft-\[(-?\d+)px\] top-\[(-?\d+)px\]/,
        hd(IxpipeApp.UI.find(w, "select_1"))["a"]["class"]
      )

    {left, top} = {String.to_integer(left), String.to_integer(top)}

    # The canvas beside the 320px properties panel, under the header and
    # ribbon and above the 280px Results: about 880 by 300 at 1200 by 800.
    assert left >= 0 and left + 200 <= 880
    assert top >= 0 and top + 120 <= 300
  end

  # On a window with room beside the cards, the new tool goes there, in view,
  # and the view stays where it was.
  test "a new tool uses open space in view before panning", ctx do
    File.write!(Path.join(ctx.dir, "wide.yaml"), """
    name: wide
    nodes:
      - {id: a, tool: input_csv, position: {x: 20, y: 30}, config: {path: x.csv}}
      - {id: b, tool: input_csv, position: {x: 20, y: 190}, config: {path: x.csv}}
      - {id: c, tool: sort, position: {x: 240, y: 110}, inputs: {in: a}, config: {by: [id]}}
      - {id: d, tool: sort, position: {x: 460, y: 110}, inputs: {in: c}, config: {by: [id]}}
      - {id: e, tool: sort, position: {x: 680, y: 30}, inputs: {in: d}, config: {by: [id]}}
      - {id: f, tool: sort, position: {x: 680, y: 190}, inputs: {in: d}, config: {by: [id]}}
    """)

    w = ctx.window

    pid =
      start_supervised!(
        {IxpipeApp.MainView,
         window: w,
         theme: IxpipeApp.Theme,
         args: [dir: ctx.dir, path: Path.join(ctx.dir, "wide.yaml")]}
      )

    Test.resize(w, 1600, 1000)
    IxpipeApp.UI.add(w, "select")

    assigns = :sys.get_state(pid).assigns
    assert assigns.pan == {0, 0}
    %{"x" => x, "y" => y} = Enum.find(assigns.spec.nodes, &(&1.id == "select_1")).position
    # Beside the cards (which end at x 880), inside the 1279px-wide canvas.
    assert x >= 880 and x + 200 <= 1279
    assert y + 170 <= 1000 - 491
  end
end
