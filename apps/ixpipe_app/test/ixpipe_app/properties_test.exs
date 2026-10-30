defmodule IxpipeApp.PropertiesTest do
  # Configuring tools in the properties panel, and browsing a tool's output
  # in the results grid, as in Alteryx's Configuration and Results windows.
  use ExUnit.Case, async: false
  alias Baguette.Test
  alias IxpipeCore.Spec

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-props-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "sales.yaml"), """
    name: sales
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
    """)

    window = System.unique_integer([:positive])

    start_supervised!(
      {IxpipeApp.MainView,
       window: window,
       theme: IxpipeApp.Theme,
       args: [dir: dir, path: Path.join(dir, "sales.yaml")]}
    )

    %{w: window, dir: dir}
  end

  defp saved(dir) do
    {:ok, spec} = dir |> Path.join("sales.yaml") |> File.read!() |> Spec.decode()
    Map.new(spec.nodes, &{&1.id, &1})
  end

  test "with nothing selected, the panels say what to do", %{w: w} do
    assert Test.text(w) =~ "Select a tool to configure it."
    assert Test.text(w) =~ "Select a tool to see its results."
  end

  test "selecting a tool shows its settings, labelled, with current values", %{w: w} do
    Test.click(w, "Select orders")
    assert Test.text(w) =~ "File"
    assert Test.value(w, "File") == "#{@fixtures}/orders.csv"
  end

  test "a new tool is selected, and editing a setting changes the workflow", %{w: w, dir: dir} do
    IxpipeApp.UI.add(w, "sort")
    Test.fill(w, "Sort by", "amount, id")
    Test.click(w, "Save workflow")
    assert saved(dir)["sort_1"].config == %{"by" => ["amount", "id"]}
  end

  test "an invalid value shows why and leaves the workflow as it was", %{w: w, dir: dir} do
    IxpipeApp.UI.add(w, "sample")
    Test.fill(w, "Rows", "abc")
    assert Test.text(w) =~ "Enter a whole number"
    assert Test.value(w, "Rows") == "abc"

    Test.click(w, "Save workflow")
    assert saved(dir)["sample_1"].config == %{}

    Test.fill(w, "Rows", "2")
    refute Test.text(w) =~ "Enter a whole number"
  end

  test "choices and switches", %{w: w, dir: dir} do
    IxpipeApp.UI.add(w, "join")
    Test.click(w, "Join type left")
    IxpipeApp.UI.add(w, "sort")
    Test.click(w, "Descending")
    Test.click(w, "Save workflow")
    assert saved(dir)["join_1"].config == %{"how" => "left"}
    assert saved(dir)["sort_1"].config == %{"desc" => true}
  end

  test "formulas: one row each, and Add formula adds a row", %{w: w, dir: dir} do
    IxpipeApp.UI.add(w, "formula")
    Test.fill(w, "Formula 1", "taxed = amount * 2")
    Test.click(w, "Add a formula")
    Test.fill(w, "Formula 2", "big = taxed > 50")
    Test.click(w, "Save workflow")

    assert saved(dir)["formula_1"].config == %{
             "formulas" => [
               %{"as" => "taxed", "expr" => "amount * 2"},
               %{"as" => "big", "expr" => "taxed > 50"}
             ]
           }
  end

  test "after a run, the results grid shows the selected tool's rows", %{w: w} do
    Test.click(w, "Run workflow")
    Test.click(w, "Select orders")

    text = Test.text(w)
    assert text =~ "Results"
    assert text =~ "2 rows"
    assert text =~ "id"
    assert text =~ "amount"
    assert text =~ "50"
  end

  test "before a run, the results grid says how to fill it", %{w: w} do
    Test.click(w, "Select orders")
    assert Test.text(w) =~ "Run the workflow to see this tool's results."
  end

  test "a reshaping tool is configured in the panel and runs", %{w: w} do
    IxpipeApp.UI.add(w, "transpose")
    Test.click(w, "Connect from orders")
    Test.click(w, "Connect to transpose_1 in")
    Test.fill(w, "Key columns", "id")
    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "Run succeeded"
    Test.click(w, "Select transpose_1")
    assert Test.text(w) =~ "name"
    assert Test.text(w) =~ "amount"
  end
end
