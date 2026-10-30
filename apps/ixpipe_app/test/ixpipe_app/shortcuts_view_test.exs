defmodule IxpipeApp.ShortcutsViewTest do
  # Keyboard shortcuts on the canvas, through phx-window-keydown. Ctrl and
  # Cmd (meta) are the same command key, so they work on every platform.
  use ExUnit.Case, async: false
  alias Baguette.Test
  alias IxpipeApp.UI

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-keys-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "sales.yaml"), """
    name: sales
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
    """)

    w = System.unique_integer([:positive])

    pid =
      start_supervised!(
        {IxpipeApp.MainView,
         window: w, theme: IxpipeApp.Theme, args: [dir: dir, path: Path.join(dir, "sales.yaml")]}
      )

    %{w: w, pid: pid, dir: dir}
  end

  defp assigns(pid), do: :sys.get_state(pid).assigns
  defp ids(pid), do: Enum.map(assigns(pid).spec.nodes, & &1.id)

  test "Ctrl+Z undoes; Ctrl+Shift+Z and Ctrl+Y redo", %{w: w, pid: pid} do
    UI.add(w, "sort")
    assert length(ids(pid)) == 2

    Test.keydown(w, "z", [:ctrl])
    assert ids(pid) == ["orders"]
    Test.keydown(w, "z", [:ctrl, :shift])
    assert length(ids(pid)) == 2

    Test.keydown(w, "z", [:meta])
    assert ids(pid) == ["orders"]
    Test.keydown(w, "y", [:ctrl])
    assert length(ids(pid)) == 2
  end

  test "Ctrl+S saves, even from a text field", %{w: w, dir: dir} do
    File.write!(Path.join(dir, "sales.yaml"), "stale")
    Test.click(w, "Select orders")
    Test.keydown(w, "s", [:ctrl], focus: "File")
    assert File.read!(Path.join(dir, "sales.yaml")) =~ "orders"
    assert Test.text(w) =~ "Saved sales.yaml"
  end

  test "Ctrl+Enter runs the workflow", %{w: w} do
    Test.keydown(w, "Enter", [:ctrl])
    assert Test.text(w) =~ "Run succeeded"
  end

  test "Ctrl+= and Ctrl+- zoom; Ctrl+0 restores the view", %{w: w, pid: pid} do
    Test.keydown(w, "=", [:ctrl])
    assert assigns(pid).zoom == 125
    Test.keydown(w, "-", [:ctrl])
    Test.keydown(w, "-", [:ctrl])
    assert assigns(pid).zoom == 75
    Test.keydown(w, "0", [:ctrl])
    assert assigns(pid).zoom == 100
  end

  test "keys without Ctrl or Cmd, and typing in a field, do nothing", %{w: w, pid: pid} do
    UI.add(w, "sort")
    before = assigns(pid)
    Test.keydown(w, "z")
    Test.keydown(w, "z", [:ctrl], focus: "Sort by")
    Test.keydown(w, "=", [:shift])
    Test.keydown(w, "s", [:alt])
    assert assigns(pid).spec == before.spec and assigns(pid).zoom == before.zoom
    assert assigns(pid).toast == nil
  end

  test "each Home command and header button shows its shortcut as a tooltip", %{w: w} do
    titles =
      for label <- [
            "Undo",
            "Redo",
            "Zoom out",
            "Zoom in",
            "Restore view",
            "Save workflow",
            "Run workflow"
          ],
          into: %{},
          do: {label, hd(UI.find(w, label))["a"]["title"]}

    assert titles == %{
             "Undo" => "Undo (Ctrl+Z)",
             "Redo" => "Redo (Ctrl+Shift+Z)",
             "Zoom out" => "Zoom out (Ctrl+-)",
             "Zoom in" => "Zoom in (Ctrl+=)",
             "Restore view" => "Restore view (Ctrl+0)",
             "Save workflow" => "Save workflow (Ctrl+S)",
             "Run workflow" => "Run workflow (Ctrl+Enter)"
           }
  end
end
