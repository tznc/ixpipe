defmodule IxpipeApp.CodeToolsTest do
  # The Code tab: sandboxed Python and Script (code in a runtime installed
  # on this computer). Code is edited a line per row, in monospace; a run
  # shows each tool's table and its log, and a failure its traceback.
  use ExUnit.Case, async: false
  alias Baguette.Test
  alias IxpipeApp.UI
  alias IxpipeCore.Spec

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-code-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "sales.yaml"), """
    name: sales
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
    """)

    %{dir: dir, w: System.unique_integer([:positive])}
  end

  defp start(%{dir: dir, w: w}, args \\ []) do
    start_supervised!(
      {IxpipeApp.MainView,
       window: w,
       theme: IxpipeApp.Theme,
       args: [dir: dir, path: Path.join(dir, "sales.yaml")] ++ args}
    )

    w
  end

  defp saved(dir) do
    {:ok, spec} = dir |> Path.join("sales.yaml") |> File.read!() |> Spec.decode()
    Map.new(spec.nodes, &{&1.id, &1})
  end

  defp python(w, lines) do
    UI.add(w, "python")
    Test.click(w, "Connect from orders")
    Test.click(w, "Connect to python_1 in")

    for {line, i} <- Enum.with_index(lines, 1) do
      if i > 1, do: Test.click(w, "Add a line")
      Test.fill(w, "Script line #{i}", line)
    end
  end

  test "the Code tab holds Python and Script, each with its icon", ctx do
    w = start(ctx)
    Test.click(w, "Code tab")
    assert UI.find(w, "Code") != []
    assert Test.icons(w, "Add python") == ["square-code"]
    assert Test.icons(w, "Add script") == ["square-terminal"]
    assert Test.text(w) =~ "Python"
    assert Test.text(w) =~ "Script"
  end

  test "code is edited a line per row, in monospace, and saved as one setting", ctx do
    w = start(ctx)
    python(w, ["rows = inputs['in']", "output = rows"])
    assert hd(UI.find(w, "Script line 1"))["a"]["class"] =~ "font-mono"

    Test.click(w, "Save workflow")
    assert saved(ctx.dir)["python_1"].config == %{"code" => "rows = inputs['in']\noutput = rows"}
  end

  test "a pasted multi-line script becomes one row per line", ctx do
    w = start(ctx)
    python(w, ["a = 1\nb = 2\noutput = []"])
    assert Test.value(w, "Script line 3") == "output = []"
  end

  test "a run shows the script's table and, as log, what it printed", ctx do
    w = start(ctx)
    python(w, ["print('hello from python')", "output = [{'n': len(inputs['in'])}]"])
    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "Run succeeded"

    Test.click(w, "Select python_1")
    assert Test.text(w) =~ "1 row"
    Test.click(w, "Show log output")
    assert Test.text(w) =~ "hello from python"
    assert Test.text(w) =~ "stdout"
  end

  test "a failing script: the callout says what happened, Results shows the traceback", ctx do
    w = start(ctx)
    python(w, ["x = 1", "output = x / 0"])
    Test.click(w, "Select orders")
    Test.click(w, "Run workflow")

    text = Test.text(w)
    assert text =~ "python_1 failed."
    assert text =~ "Python raised ZeroDivisionError on line 2: division by zero."
    assert text =~ "Fix the script and run again."
    refute text =~ "Fix its config"
    refute text =~ "Traceback"

    Test.click(w, "Select python_1")
    assert Test.text(w) =~ "Traceback"
    assert Test.text(w) =~ ~s(File "script.py", line 2)
  end

  test "Script names the runtime it will use, or says it's missing", ctx do
    w = start(ctx)
    UI.add(w, "script")
    assert Test.text(w) =~ ~r/Runs with \S*python3/

    Test.fill(w, "Interpreter", "/nowhere/python3")
    assert Test.text(w) =~ "Python isn't installed at /nowhere/python3."
    assert Test.text(w) =~ "set Interpreter to a Python 3 executable"
  end

  test "on a phone, Script says it runs on desktop only", ctx do
    w = start(ctx, mobile: true)
    UI.add(w, "script")
    assert Test.text(w) =~ "Script runs on desktop only"
  end
end
