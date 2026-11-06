defmodule IxpipeCore.FileToolsTest do
  use ExUnit.Case, async: true
  alias IxpipeCore.{Context, Table, Tools}

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, ctx: Context.new()}
  end

  # A workbook with an "Orders" sheet (header, ints, floats, strings, a blank
  # cell, a date) and an empty "Notes" sheet, written with Elixlsx.
  defp workbook!(dir) do
    path = Path.join(dir, "orders.xlsx")

    orders = %Elixlsx.Sheet{
      name: "Orders",
      rows: [
        ["id", "amount", "region", "when"],
        [1, 50.5, "eu", {2026, 1, 2}],
        [2, 5, nil, {2026, 3, 4}],
        [3, 30, "us", {2026, 5, 6}]
      ]
    }

    orders = put_in(orders.rows, fix_dates(orders.rows))
    workbook = %Elixlsx.Workbook{sheets: [orders, %Elixlsx.Sheet{name: "Notes", rows: []}]}
    {:ok, _} = Elixlsx.write_to(workbook, String.to_charlist(path))
    path
  end

  defp fix_dates(rows) do
    for row <- rows,
        do:
          for(
            cell <- row,
            do: if(is_tuple(cell), do: [{cell, {0, 0, 0}}, yyyymmdd: true], else: cell)
          )
  end

  test "the new tools are registered with their fields" do
    assert Tools.lookup("input_excel") == Tools.InputExcel
    assert Tools.lookup("output_excel") == Tools.OutputExcel
    assert Tools.lookup("input_parquet") == Tools.InputParquet
    assert Tools.lookup("output_parquet") == Tools.OutputParquet

    assert [%{key: "path", label: "File", type: :path} | _] = Tools.InputParquet.fields()

    assert [
             %{key: "path", label: "File", type: :path},
             %{key: "sheet", label: "Sheet", type: :string, optional: true},
             %{key: "range", label: "Cell range", type: :string, optional: true},
             %{key: "header", label: "First row is the header", type: :bool, optional: true}
           ] = Tools.InputExcel.fields()

    assert Tools.required(Tools.InputExcel) == ["path"]
    assert Tools.required(Tools.OutputExcel) == ["path"]
  end

  describe "input_excel" do
    test "reads the first sheet, with typed columns", %{dir: dir, ctx: ctx} do
      df = Tools.InputExcel.run(%{}, %{"path" => workbook!(dir)}, ctx)
      assert Table.columns(df) == ["id", "amount", "region", "when"]

      cols = Table.to_columns(df)
      assert cols["id"] == [1, 2, 3]
      assert cols["amount"] == [50.5, 5.0, 30.0]
      assert cols["region"] == ["eu", nil, "us"]

      assert cols["when"] == [~D[2026-01-02], ~D[2026-03-04], ~D[2026-05-06]]

      assert Table.dtypes(df) == %{
               "id" => "BIGINT",
               "amount" => "DOUBLE",
               "region" => "VARCHAR",
               "when" => "DATE"
             }
    end

    test "without a header row, columns are column_1, column_2, ...", %{dir: dir, ctx: ctx} do
      df = Tools.InputExcel.run(%{}, %{"path" => workbook!(dir), "header" => false}, ctx)
      assert Table.columns(df) == ["column_1", "column_2", "column_3", "column_4"]
      assert Table.count(df) == 4
    end

    test "reads a named sheet; an empty sheet has no rows", %{dir: dir, ctx: ctx} do
      df = Tools.InputExcel.run(%{}, %{"path" => workbook!(dir), "sheet" => "Notes"}, ctx)
      assert Table.count(df) == 0
      # A DuckDB table needs a column; the old engine allowed a frame with none.
      assert Table.dtypes(df) == %{"column_1" => "VARCHAR"}
    end

    test "an unknown sheet names the sheets there are", %{dir: dir, ctx: ctx} do
      assert_raise RuntimeError, "No sheet named Nope. Sheets: Orders, Notes", fn ->
        Tools.InputExcel.run(%{}, %{"path" => workbook!(dir), "sheet" => "Nope"}, ctx)
      end
    end

    test "blank and repeated headers get column_N names", %{dir: dir, ctx: ctx} do
      path = Path.join(dir, "headers.xlsx")
      sheet = %Elixlsx.Sheet{name: "S", rows: [["a", nil, "a"], [1, 2, 3]]}
      {:ok, _} = Elixlsx.write_to(%Elixlsx.Workbook{sheets: [sheet]}, String.to_charlist(path))

      df = Tools.InputExcel.run(%{}, %{"path" => path}, ctx)
      assert Table.columns(df) == ["a", "column_2", "column_3"]
    end
  end

  describe "output_excel and parquet" do
    test "output_excel writes a sheet that input_excel reads back, and passes through", %{
      dir: dir,
      ctx: ctx
    } do
      df = Table.new(ctx.db, "src", id: [1, 2], name: ["Ada", nil], score: [1.5, 2.0])
      path = Path.join(dir, "out.xlsx")

      assert Tools.OutputExcel.run(%{"in" => df}, %{"path" => path, "sheet" => "Scores"}, ctx) ==
               df

      back = Tools.InputExcel.run(%{}, %{"path" => path, "sheet" => "Scores"}, ctx)

      assert Table.to_columns(back) == %{
               "id" => [1, 2],
               "name" => ["Ada", nil],
               "score" => [1.5, 2.0]
             }
    end

    test "output_excel names its sheet Sheet1 by default", %{dir: dir, ctx: ctx} do
      path = Path.join(dir, "default.xlsx")
      Tools.OutputExcel.run(%{"in" => Table.new(ctx.db, "src", a: [1])}, %{"path" => path}, ctx)

      assert Table.count(Tools.InputExcel.run(%{}, %{"path" => path, "sheet" => "Sheet1"}, ctx)) ==
               1
    end

    test "parquet round-trips", %{dir: dir, ctx: ctx} do
      df = Table.new(ctx.db, "src", id: [1, 2], name: ["a", "b"])
      path = Path.join(dir, "data.parquet")
      assert Tools.OutputParquet.run(%{"in" => df}, %{"path" => path}, ctx) == df

      assert Table.to_columns(Tools.InputParquet.run(%{}, %{"path" => path}, ctx)) ==
               Table.to_columns(df)
    end

    test "a workflow converts Excel to Parquet and back", %{dir: dir, ctx: ctx} do
      xlsx = workbook!(dir)
      parquet = Path.join(dir, "orders.parquet")
      out = Path.join(dir, "orders-copy.xlsx")

      {:ok, spec} =
        IxpipeCore.Spec.parse("""
        nodes:
          - {id: book, tool: input_excel, config: {path: #{xlsx}, sheet: Orders}}
          - {id: pq, tool: output_parquet, inputs: {in: book}, config: {path: #{parquet}}}
        """)

      assert {:ok, _} = IxpipeCore.run(spec)

      {:ok, spec} =
        IxpipeCore.Spec.parse("""
        nodes:
          - {id: pq, tool: input_parquet, config: {path: #{parquet}}}
          - {id: book, tool: output_excel, inputs: {in: pq}, config: {path: #{out}}}
        """)

      assert {:ok, %{"pq" => df}} = IxpipeCore.run(spec)
      assert Table.to_columns(df)["amount"] == [50.5, 5.0, 30.0]
      assert Table.count(Tools.InputExcel.run(%{}, %{"path" => out}, ctx)) == 3
    end
  end
end
