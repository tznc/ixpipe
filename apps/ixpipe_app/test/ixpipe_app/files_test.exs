defmodule IxpipeApp.FilesTest do
  # File tools: Excel and Parquet in the palette, and native file pickers
  # for every File setting.
  use ExUnit.Case, async: false
  alias Baguette.Test

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "flow.yaml"), "name: flow\nnodes: []\n")
    window = System.unique_integer([:positive])

    pid =
      start_supervised!(
        {IxpipeApp.MainView,
         window: window,
         theme: IxpipeApp.Theme,
         args: [dir: dir, path: Path.join(dir, "flow.yaml")]}
      )

    %{w: window, pid: pid}
  end

  defp picker(w, label) do
    [el] = Test.find_all(w, label)
    el["a"]
  end

  test "Excel and Parquet tools are on the In/Out tab", %{w: w} do
    Test.click(w, "In/Out tab")

    for tool <- ~w(input_excel output_excel input_parquet output_parquet),
        do: assert(IxpipeApp.UI.find(w, "Add #{tool}") != [])
  end

  test "an input's File setting has a picker filtered to its format", %{w: w} do
    IxpipeApp.UI.add(w, "input_excel")
    assert %{"phx-pick-file" => _, "accept" => "xlsx"} = picker(w, "Choose file")

    Test.pick_file(w, "Choose file", "/data/sales.xlsx")
    assert Test.value(w, "File") == "/data/sales.xlsx"
    assert Test.text(w) =~ "Sheet"
  end

  test "an output's File setting opens a save dialog", %{w: w, pid: pid} do
    IxpipeApp.UI.add(w, "output_parquet")
    assert %{"phx-pick-save" => _, "accept" => "parquet"} = picker(w, "Choose file")

    Test.pick_file(w, "Choose file", "/out/result.parquet")
    spec = :sys.get_state(pid).assigns.spec
    assert hd(spec.nodes).config == %{"path" => "/out/result.parquet"}
  end

  test "a switch with no setting shows the tool's default", %{w: w} do
    IxpipeApp.UI.add(w, "input_excel")

    [checkbox] =
      for %{"t" => "input", "a" => %{"aria-label" => "First row is the header"} = a} <-
            Test.find_all(w, "First row is the header"),
          do: a

    assert Map.has_key?(checkbox, "checked")
  end
end
