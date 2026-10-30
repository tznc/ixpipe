defmodule IxpipeApp.SelectBrowseTest do
  # Alteryx's two most-used experiences: the Select tool's column editor
  # (keep, rename, retype and reorder each column) and browsing a tool's
  # whole output in Results (pages, sorting and a profile of each column).
  use ExUnit.Case, async: false
  alias Baguette.Test
  alias IxpipeApp.UI
  alias IxpipeCore.Spec

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-select-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    csv = Path.join(dir, "orders.csv")

    lines =
      for i <- 1..120,
          do:
            "#{i},#{if rem(i, 40) == 0, do: "n/a", else: i * 2},#{if rem(i, 3) == 0, do: "Oslo", else: "Rome"}"

    File.write!(csv, Enum.join(["id,amount,city" | lines], "\n") <> "\n")

    File.write!(Path.join(dir, "sales.yaml"), """
    name: sales
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{csv}}}
      - {id: pick, tool: select, position: {x: 280, y: 40}, inputs: {in: orders}}
      - {id: old, tool: select, position: {x: 280, y: 220}, inputs: {in: orders}, config: {columns: [city]}}
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

  defp saved(w, dir) do
    Test.click(w, "Save workflow")
    {:ok, spec} = dir |> Path.join("sales.yaml") |> File.read!() |> Spec.decode()
    Map.new(spec.nodes, &{&1.id, &1.config})
  end

  defp run(w) do
    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "Run succeeded"
  end

  describe "the Select editor" do
    test "before a run it says how to load the columns", %{w: w} do
      Test.click(w, "Select pick")
      assert Test.text(w) =~ "Run the workflow to load this tool's columns."
    end

    test "after a run, one row per input column, all kept", %{w: w} do
      run(w)
      Test.click(w, "Select pick")
      assert Test.value(w, "Name of id") == "id"
      assert Test.value(w, "Name of amount") == "amount"
      assert Test.value(w, "Name of city") == "city"
      [keep] = UI.find(w, "Keep city")
      assert Map.has_key?(keep["a"], "checked")
      assert Test.text(w) =~ "BIGINT"
    end

    test "keep, rename, move and the new-columns policy edit the config", %{w: w, dir: dir} do
      run(w)
      Test.click(w, "Select pick")
      Test.click(w, "Keep city")
      Test.fill(w, "Name of amount", "total")
      Test.click(w, "Move amount up")
      Test.click(w, "New columns drop")

      assert saved(w, dir)["pick"] == %{
               "columns" => [
                 %{"name" => "amount", "rename" => "total"},
                 %{"name" => "id"},
                 %{"name" => "city", "keep" => false}
               ],
               "new_columns" => "drop"
             }

      run(w)
      Test.click(w, "Select pick")
      text = Test.text(w)
      assert text =~ "total"
      refute text =~ "Rome"
    end

    test "a type change casts with TRY_CAST and reports the NULLs", %{w: w, dir: dir} do
      run(w)
      Test.click(w, "Select pick")
      Test.click(w, "Type of amount")
      Test.click(w, "Cast amount to DOUBLE")

      assert saved(w, dir)["pick"]["columns"] |> Enum.at(1) == %{
               "name" => "amount",
               "type" => "DOUBLE"
             }

      Test.click(w, "Run workflow")
      text = Test.text(w)
      assert text =~ "Run succeeded with 1 warning"
      assert text =~ "amount: 3 values couldn't become DOUBLE and are now NULL."
    end

    test "any DuckDB type can be typed; a wrong one says what to do", %{w: w, dir: dir} do
      run(w)
      Test.click(w, "Select pick")
      Test.click(w, "Type of id")
      Test.fill(w, "Another type for id", "nope")
      assert Test.text(w) =~ "nope is not a type"
      Test.fill(w, "Another type for id", "DECIMAL(10,2)")
      assert hd(saved(w, dir)["pick"]["columns"]) == %{"name" => "id", "type" => "DECIMAL(10,2)"}
    end

    test "a plain column list still works, and shows unlisted columns dropped", %{w: w} do
      run(w)
      Test.click(w, "Select old")
      [city] = UI.find(w, "Keep city")
      [id] = UI.find(w, "Keep id")
      assert Map.has_key?(city["a"], "checked")
      refute Map.has_key?(id["a"], "checked")
      assert Test.text(w) =~ "old · 120 rows"
    end
  end

  describe "browsing results" do
    test "pages through every row", %{w: w} do
      run(w)
      Test.click(w, "Select orders")
      assert Test.text(w) =~ "orders · 120 rows"
      assert Test.text(w) =~ "Rows 1–50"
      Test.click(w, "Next page")
      Test.click(w, "Next page")
      assert Test.text(w) =~ "Rows 101–120"
      assert Test.text(w) =~ "120"
      [next] = UI.find(w, "Next page")
      assert Map.has_key?(next["a"], "disabled")
      Test.click(w, "Previous page")
      assert Test.text(w) =~ "Rows 51–100"
    end

    test "a column header sorts, ascending then descending then off", %{w: w} do
      run(w)
      Test.click(w, "Select orders")
      Test.click(w, "Sort by id")
      assert first_id(w) == "1"
      Test.click(w, "Sort by id")
      assert first_id(w) == "120"
      assert Test.icons(w, "Sort by id") == ["arrow-down"]
      Test.click(w, "Sort by id")
      assert first_id(w) == "1"
      assert Test.icons(w, "Sort by id") == []
    end

    test "a profile of each column", %{w: w} do
      run(w)
      Test.click(w, "Select orders")
      Test.click(w, "Show profile")
      text = Test.text(w)
      assert text =~ "Distinct"
      assert text =~ "Rome (80), Oslo (40)"
      assert text =~ "1 – 120"
      assert text =~ "VARCHAR"
      assert text =~ "Nulls"
      Test.click(w, "Show data")
      assert Test.text(w) =~ "Rows 1–50"
    end

    test "on a phone, Results browses too, with touch-size controls", %{w: w} do
      Test.resize(w, 390, 844)
      Test.click(w, "Select orders")
      run(w)
      assert UI.find(w, "Results") != []
      Test.click(w, "Next page")
      assert Test.text(w) =~ "Rows 51–100"

      for label <- ["Next page", "Sort by id", "Show profile"] do
        [button] = UI.find(w, label)
        assert button["a"]["class"] =~ "min-h-10"
      end
    end
  end

  # The first cell of the grid's first row.
  defp first_id(w) do
    [grid] = UI.find(w, "Rows")
    grid |> texts() |> Enum.at(3)
  end

  defp texts(text) when is_binary(text), do: [text]
  defp texts(%{"c" => children}), do: Enum.flat_map(children, &texts/1)
end
