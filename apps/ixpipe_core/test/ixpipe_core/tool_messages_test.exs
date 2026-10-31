defmodule IxpipeCore.ToolMessagesTest do
  use ExUnit.Case, async: true
  alias IxpipeCore.{Context, Table, Tools}

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-msg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, ctx: Context.new("n")}
  end

  defp warnings(ctx), do: for(%{level: :warning, text: t} <- Context.messages(ctx), do: t)
  defp infos(ctx), do: for(%{level: :info, text: t} <- Context.messages(ctx), do: t)

  describe "Input CSV" do
    test "skips rows that fail to parse and says how many", %{dir: dir, ctx: ctx} do
      path = Path.join(dir, "bad.csv")
      File.write!(path, "id,amount\n1,10\n2,20,extra,more\n3,30\n")

      t = Tools.InputCsv.run(%{}, %{"path" => path}, ctx)

      assert Table.to_columns(t)["id"] == [1, 3]
      assert [warning] = warnings(ctx)
      assert warning =~ "1 row couldn't be read and was skipped (line 3"
      assert warning =~ "Fix it in the file"
    end

    test "warns about a column of numbers read as text", %{dir: dir, ctx: ctx} do
      path = Path.join(dir, "text.csv")
      File.write!(path, "id,amount\n1,10\n2,n/a\n3,30\n4,40\n")

      Tools.InputCsv.run(%{}, %{"path" => path}, ctx)

      assert [warning] = warnings(ctx)
      assert warning =~ ~s|Column "amount" is read as text: 1 of 4 values isn't a number ("n/a")|
      assert warning =~ "Data cleansing"
    end

    test "a clean file has no warnings", %{dir: dir, ctx: ctx} do
      path = Path.join(dir, "ok.csv")
      File.write!(path, "id,name\n1,Ada\n2,Bob\n")
      Tools.InputCsv.run(%{}, %{"path" => path}, ctx)
      assert warnings(ctx) == []
    end
  end

  test "Formula warns when a result is NULL on every row", %{ctx: ctx} do
    src = Table.sql(ctx.db, "src", "SELECT * FROM (VALUES (1, NULL::INTEGER), (2, NULL)) t(a, b)")
    formulas = [%{"as" => "c", "expr" => "a + b"}, %{"as" => "d", "expr" => "a * 2"}]
    Tools.Formula.run(%{"in" => src}, %{"formulas" => formulas}, ctx)

    assert [warning] = warnings(ctx)
    assert warning =~ ~s(Formula "c" is NULL on every row.)
    assert warning =~ "COALESCE"
  end

  test "Join warns when keys have different types", %{ctx: ctx} do
    left = Table.new(ctx.db, "l", id: [1, 2])
    right = Table.new(ctx.db, "r", id: ["1", "2"])

    try do
      Tools.Join.run(%{"left" => left, "right" => right}, %{"on" => ["id"]}, ctx)
    rescue
      _ -> :ok
    end

    assert [warning] = warnings(ctx)
    assert warning =~ ~s(Join key "id" is BIGINT on the left and VARCHAR on the right.)
    assert warning =~ "Formula"
  end

  test "Join keys of one kind of number don't warn", %{ctx: ctx} do
    left = Table.sql(ctx.db, "l", "SELECT 1::INTEGER AS id")
    right = Table.new(ctx.db, "r", id: [1])
    Tools.Join.run(%{"left" => left, "right" => right}, %{"on" => ["id"]}, ctx)
    assert warnings(ctx) == []
  end

  test "Input Excel empties cells it couldn't read and says where", %{dir: dir, ctx: ctx} do
    path = Path.join(dir, "errors.xlsx")
    sheet = %Elixlsx.Sheet{name: "S", rows: [["a", "b"], [1, "#DIV/0!"], [2, "#N/A"], [3, 4]]}
    {:ok, _} = Elixlsx.write_to(%Elixlsx.Workbook{sheets: [sheet]}, String.to_charlist(path))

    t = Tools.InputExcel.run(%{}, %{"path" => path}, ctx)

    assert Table.to_columns(t)["b"] == [nil, nil, 4]
    assert [warning] = warnings(ctx)
    assert warning =~ "2 cells couldn't be read and are empty (#DIV/0! in B2)"
  end

  test "Input Excel explains a file it can't open", %{dir: dir, ctx: ctx} do
    path = Path.join(dir, "missing.xlsx")

    assert_raise RuntimeError, ~r/can't be opened/, fn ->
      Tools.InputExcel.run(%{}, %{"path" => path}, ctx)
    end
  end

  test "output tools report the rows written and where", %{dir: dir, ctx: ctx} do
    src = Table.new(ctx.db, "src", a: [1, 2, 3])

    for {tool, file} <- [
          {Tools.OutputCsv, "o.csv"},
          {Tools.OutputParquet, "o.parquet"},
          {Tools.OutputExcel, "o.xlsx"}
        ] do
      path = Path.join(dir, file)
      tool.run(%{"in" => src}, %{"path" => path}, ctx)
      assert "Wrote 3 rows to #{path}." in infos(ctx)
    end
  end
end
