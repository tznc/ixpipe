defmodule IxpipeApp.RibbonViewTest do
  # The canvas's commands live in a ribbon, as in ixtable (after Access): a
  # row of tabs over labelled command groups. Home edits and views the
  # workflow; the other tabs hold the tools, by category.
  use ExUnit.Case, async: false
  alias Baguette.Test
  alias IxpipeApp.UI

  @tool_tabs ["In/Out tab", "Preparation tab", "Join tab", "Parse tab", "Transform tab"]

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-ribbon-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "flow.yaml"), "name: flow\nnodes: []\n")
    w = System.unique_integer([:positive])

    pid =
      start_supervised!(
        {IxpipeApp.MainView,
         window: w, theme: IxpipeApp.Theme, args: [dir: dir, path: Path.join(dir, "flow.yaml")]}
      )

    %{w: w, pid: pid}
  end

  defp attrs(w, label), do: hd(UI.find(w, label))["a"]

  defp commands(w) do
    for {:click, "Add " <> _ = label} <- UI.actions(w), do: label
  end

  test "Home is open first, with the Edit and View groups", %{w: w} do
    assert attrs(w, "Home tab")["aria-selected"] == "true"
    assert attrs(w, "Edit")["role"] == "group"
    assert attrs(w, "View")["role"] == "group"

    for command <- ["Undo", "Redo", "Zoom out", "Zoom in", "Restore view"],
        do: assert(UI.find(w, command) != [], command)
  end

  test "a tab shows only its own groups", %{w: w} do
    Test.click(w, "Preparation tab")
    assert attrs(w, "Preparation tab")["aria-selected"] == "true"
    assert attrs(w, "Home tab")["aria-selected"] == "false"
    assert UI.find(w, "Columns") != []
    assert UI.find(w, "Rows") != []
    assert UI.find(w, "Undo") == []
  end

  test "every tool is on exactly one tab", %{w: w} do
    added =
      Enum.flat_map(@tool_tabs, fn tab ->
        Test.click(w, tab)
        commands(w)
      end)

    assert Enum.sort(added) == Enum.map(IxpipeCore.Tools.names(), &"Add #{&1}")
  end

  test "the everyday tools sit in Preparation and Join, humanised", %{w: w} do
    Test.click(w, "Preparation tab")
    assert attrs(w, "Sequence")["role"] == "group"

    for label <- [
          "Record ID",
          "Running total",
          "Tile",
          "Generate rows",
          "Imputation",
          "Auto field"
        ],
        do: assert(Test.text(w) =~ label, label)

    Test.click(w, "Join tab")
    assert attrs(w, "Match")["role"] == "group"

    for label <- ["Find replace", "Append fields", "Join multiple", "Fuzzy match"],
        do: assert(Test.text(w) =~ label, label)
  end

  test "a tool added from a tab lands on the canvas", %{w: w, pid: pid} do
    Test.click(w, "In/Out tab")
    assert Test.text(w) =~ "Input"
    IxpipeApp.UI.add(w, "input_csv")
    assert [%{tool: IxpipeCore.Tools.InputCsv}] = :sys.get_state(pid).assigns.spec.nodes
  end

  test "the ribbon replaces the tools sidebar and the floating view toolbar", %{w: w} do
    assert UI.find(w, "Tools") == []
    assert attrs(w, "View")["class"] =~ "flex-col"
  end

  test "Home commands and the header buttons carry ixtable's icons", %{w: w} do
    icons =
      for label <- [
            "Undo",
            "Redo",
            "Zoom out",
            "Zoom in",
            "Restore view",
            "Save workflow",
            "Run workflow"
          ],
          do: Test.icons(w, label)

    assert icons == [
             ["undo-2"],
             ["redo-2"],
             ["zoom-out"],
             ["zoom-in"],
             ["scan"],
             ["save"],
             ["play"]
           ]
  end

  test "every tool command has its own icon", %{w: w} do
    icons =
      Enum.flat_map(@tool_tabs, fn tab ->
        Test.click(w, tab)
        for label <- commands(w), do: {label, Test.icons(w, label)}
      end)

    assert length(icons) == length(IxpipeCore.Tools.names())
    for {label, names} <- icons, do: assert([_] = names, label)

    # Inputs and outputs share a format's icon; every other tool has its own.
    by_tool =
      for {"Add " <> tool, [name]} <- icons,
          do: {String.replace(tool, ~r/^(in|out)put_/, ""), name}

    assert by_tool |> Enum.uniq() |> Enum.map(&elem(&1, 1)) |> then(&(&1 == Enum.uniq(&1)))
  end
end
