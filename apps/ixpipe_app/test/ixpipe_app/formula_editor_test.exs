defmodule IxpipeApp.FormulaEditorTest do
  # The formula tools in the properties panel: Multi-Row Formula,
  # Multi-Field Formula and DateTime, and the function reference (search,
  # categories, click to insert, completions of the word being typed) that
  # every expression field gets.
  use ExUnit.Case, async: false
  alias Baguette.Test
  alias IxpipeApp.UI
  alias IxpipeCore.Spec

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-fx-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "sales.yaml"), """
    name: sales
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
    """)

    w = System.unique_integer([:positive])

    start_supervised!(
      {IxpipeApp.MainView,
       window: w, theme: IxpipeApp.Theme, args: [dir: dir, path: Path.join(dir, "sales.yaml")]}
    )

    %{w: w, dir: dir}
  end

  defp saved(%{w: w, dir: dir}) do
    Test.click(w, "Save workflow")
    {:ok, spec} = dir |> Path.join("sales.yaml") |> File.read!() |> Spec.decode()
    Map.new(spec.nodes, &{&1.id, &1.config})
  end

  test "the formula tools sit in Preparation's Formula group and Parse", %{w: w} do
    Test.click(w, "Preparation tab")
    [group] = UI.find(w, "Formula")
    labels = for %{"a" => %{"aria-label" => "Add " <> tool}} <- group["c"] |> flatten(), do: tool
    assert labels == ~w(formula multi_row_formula multi_field_formula)
    assert Test.text(w) =~ "Multi-row"
    assert Test.icons(w, "Add multi_row_formula") == ["rows-3"]
    assert Test.icons(w, "Add multi_field_formula") == ["columns-4"]

    Test.click(w, "Parse tab")
    assert Test.icons(w, "Add date_time") == ["calendar-clock"]
    assert Test.text(w) =~ "DateTime"
  end

  test "a multi-row formula is configured and runs", %{w: w} = ctx do
    UI.add(w, "multi_row_formula")
    Test.click(w, "Connect from orders")
    Test.click(w, "Connect to multi_row_formula_1 in")
    Test.click(w, "Select multi_row_formula_1")
    Test.fill(w, "Column", "previous")
    Test.fill(w, "Expression", "[Row-1:amount]")
    Test.click(w, "Rows out of range zero")

    assert saved(ctx)["multi_row_formula_1"] == %{
             "as" => "previous",
             "expr" => "[Row-1:amount]",
             "out_of_range" => "zero"
           }

    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "Run succeeded"
    assert Test.text(w) =~ "previous"
  end

  test "a DateTime shows how many values failed to parse", %{w: w} do
    UI.add(w, "date_time")
    Test.click(w, "Connect from orders")
    Test.click(w, "Connect to date_time_1 in")
    Test.click(w, "Select date_time_1")
    Test.fill(w, "Column", "id")
    Test.fill(w, "Format", "yyyy-MM-dd")
    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "failed · 2 rows"
  end

  describe "function reference" do
    setup %{w: w} do
      UI.add(w, "filter")
      :ok
    end

    test "lists functions by category, each with a signature, description and example",
         %{w: w} do
      text = Test.text(w)
      assert text =~ "Functions"
      assert text =~ "upper(text)"
      assert text =~ "Converts text to capitals."
      assert text =~ "upper('eu') → EU"

      Test.click(w, "Functions: date")
      assert Test.text(w) =~ "date_diff('day', start, end)"
      refute Test.text(w) =~ "upper(text)"
    end

    test "search narrows the list", %{w: w} do
      Test.fill(w, "Search functions", "capital")
      assert Test.text(w) =~ "upper(text)"
      refute Test.text(w) =~ "lower(text)"

      Test.fill(w, "Search functions", "zzz")
      assert Test.text(w) =~ "No functions match"
    end

    test "clicking a function inserts it into the expression", %{w: w} = ctx do
      Test.fill(w, "Condition", "amount > 10 AND")
      Test.click(w, "Insert contains")
      assert Test.value(w, "Condition") == "amount > 10 AND contains(text, find)"
      assert saved(ctx)["filter_1"] == %{"expr" => "amount > 10 AND contains(text, find)"}
    end

    test "typing a function's start offers completions", %{w: w} do
      Test.fill(w, "Condition", "starts")
      Test.click(w, "Complete starts_with")
      assert Test.value(w, "Condition") == "starts_with("
      refute UI.find(w, "Complete starts_with") != []
    end

    test "formula rows: insert and complete go to the row being typed", %{w: w} do
      UI.add(w, "formula")
      Test.fill(w, "Formula 1", "big = amount > 10")
      Test.click(w, "Add a formula")
      Test.fill(w, "Formula 2", "name = upp")
      Test.click(w, "Complete upper")
      assert Test.value(w, "Formula 2") == "name = upper("
      assert Test.value(w, "Formula 1") == "big = amount > 10"
    end

    test "only tools with expressions show it", %{w: w} do
      UI.add(w, "sort")
      refute Test.text(w) =~ "Search functions"
      assert UI.find(w, "Search functions") == []
    end
  end

  defp flatten(children),
    do:
      Enum.flat_map(children, fn
        %{"c" => c} = el -> [el | flatten(c)]
        _ -> []
      end)
end
