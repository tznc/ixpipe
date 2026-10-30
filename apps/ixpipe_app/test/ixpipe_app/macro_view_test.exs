defmodule IxpipeApp.MacroViewTest do
  # Macros in the app: the Macros ribbon tab, a macro node's card and
  # settings, opening a macro and marking macros on home.
  use ExUnit.Case, async: false
  alias Baguette.Test
  alias IxpipeApp.UI
  alias IxpipeCore.Spec

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-macros-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "sales.yaml"), """
    name: sales
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
    """)

    File.write!(Path.join(dir, "big.yaml"), """
    name: Big orders
    macro:
      parameters: [{name: threshold, type: integer, label: Threshold, default: 10}]
    nodes:
      - {id: rows, tool: macro_input, config: {columns: [amount]}}
      - {id: f, tool: filter, inputs: {in: rows}, config: {expr: "amount > {{threshold}}"}}
      - {id: big, tool: macro_output, inputs: {in: f.true}}
    """)

    w = System.unique_integer([:positive])
    %{dir: dir, w: w}
  end

  defp start(%{dir: dir, w: w}, args \\ []) do
    pid =
      start_supervised!(
        {IxpipeApp.MainView, window: w, theme: IxpipeApp.Theme, args: [dir: dir] ++ args}
      )

    {w, pid}
  end

  defp saved(dir, file) do
    path = Path.join(dir, file)
    {:ok, spec} = Spec.decode(File.read!(path), path: path)
    spec
  end

  defp use_macro(w, path) do
    Test.click(w, "Macros tab")
    Test.pick_file(w, "Use a macro", path)
  end

  test "home marks macro files", ctx do
    {w, _} = start(ctx)
    assert UI.find(w, "big.yaml is a macro") != []
    assert UI.find(w, "sales.yaml is a macro") == []
  end

  test "the Macros tab adds Macro input and Macro output", ctx do
    {w, pid} = start(ctx, path: Path.join(ctx.dir, "sales.yaml"))
    UI.add(w, "macro_input")
    UI.add(w, "macro_output")
    tools = Enum.map(:sys.get_state(pid).assigns.spec.nodes, & &1.tool)
    assert IxpipeCore.Tools.MacroInput in tools
    assert IxpipeCore.Tools.MacroOutput in tools
    assert Test.text(w) =~ "Macro input"
  end

  test "Use a macro adds a node with the macro's name, ports and parameters", ctx do
    {w, _} = start(ctx, path: Path.join(ctx.dir, "sales.yaml"))
    use_macro(w, Path.join(ctx.dir, "big.yaml"))

    assert Test.text(w) =~ "Big orders"
    assert UI.find(w, "Connect to macro_1 rows") != []
    assert UI.find(w, "Connect from macro_1") != []
    assert UI.find(w, "Threshold") != []

    Test.fill(w, "Threshold", "20")
    Test.click(w, "Connect from orders")
    Test.click(w, "Connect to macro_1 rows")
    Test.click(w, "Save workflow")

    [_, macro] = saved(ctx.dir, "sales.yaml").nodes
    # Inside the workflows folder, the path is relative, so the folder moves.
    assert macro.config == %{"path" => "big.yaml", "threshold" => 20}
    assert macro.inputs == %{"rows" => "orders"}

    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "Run succeeded"
    assert Test.text(w) =~ "2 rows"
  end

  test "an inner failure names the inner tool", ctx do
    File.write!(Path.join(ctx.dir, "bad.yaml"), """
    nodes:
      - {id: rows, tool: macro_input}
      - {id: f, tool: filter, inputs: {in: rows}, config: {expr: "nope > 1"}}
      - {id: out, tool: macro_output, inputs: {in: f.true}}
    """)

    {w, _} = start(ctx, path: Path.join(ctx.dir, "sales.yaml"))
    use_macro(w, Path.join(ctx.dir, "bad.yaml"))
    Test.click(w, "Connect from orders")
    Test.click(w, "Connect to macro_1 rows")
    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "macro_1/f failed."
  end

  test "Open macro drills into the macro and the breadcrumb comes back", ctx do
    {w, pid} = start(ctx, path: Path.join(ctx.dir, "sales.yaml"))
    use_macro(w, Path.join(ctx.dir, "big.yaml"))
    Test.click(w, "Open macro")

    assert :sys.get_state(pid).assigns.path == Path.join(ctx.dir, "big.yaml")
    assert Test.text(w) =~ "Workflows"
    assert Test.text(w) =~ "sales.yaml"
    assert Test.text(w) =~ "big.yaml"
    assert Test.text(w) =~ "Macro output"

    # Back in the workflow, unsaved, as it was left.
    Test.click(w, "sales.yaml")
    assert :sys.get_state(pid).assigns.path == Path.join(ctx.dir, "sales.yaml")
    assert Test.text(w) =~ "macro_1"
  end

  test "a macro that can't load says why on the canvas", ctx do
    File.write!(Path.join(ctx.dir, "uses.yaml"), """
    nodes:
      - {id: m, tool: macro, position: {x: 40, y: 40}, config: {path: gone.yaml}}
    """)

    {w, _} = start(ctx, path: Path.join(ctx.dir, "uses.yaml"))
    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "m: no macro at gone.yaml"
  end

  test "every colour class resolves with a macro on the canvas", ctx do
    {w, _} = start(ctx)
    assert UI.unresolved_colours(w) == []
    Test.click(w, "Open sales.yaml")
    use_macro(w, Path.join(ctx.dir, "big.yaml"))
    assert UI.unresolved_colours(w) == []
  end
end
