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

  describe "everyday tools" do
    test "Append Fields over its limit, set to warn, appends and warns", %{ctx: ctx} do
      target = Table.new(ctx.db, "t", id: [1])
      source = Table.new(ctx.db, "s", k: [1, 2, 3])

      t =
        Tools.AppendFields.run(
          %{"target" => target, "source" => source},
          %{"limit" => 2, "too_many" => "warn"},
          ctx
        )

      assert Table.count(t) == 3
      assert [warning] = warnings(ctx)
      assert warning =~ "The source has 3 rows, over the limit of 2."
      assert warning =~ "Raise the limit"
    end

    test "Append Fields within its limit has no warnings", %{ctx: ctx} do
      target = Table.new(ctx.db, "t", id: [1])
      source = Table.new(ctx.db, "s", k: [1, 2])

      Tools.AppendFields.run(
        %{"target" => target, "source" => source},
        %{"too_many" => "warn"},
        ctx
      )

      assert warnings(ctx) == []
    end

    test "Imputation says how many values it filled in each column", %{ctx: ctx} do
      src = Table.new(ctx.db, "src", a: [1, nil, 3, nil], b: [nil, 2, 4, 6], c: [1, 2, 3, 4])

      Tools.Imputation.run(
        %{"in" => src},
        %{"columns" => ["a", "b", "c"], "method" => "mean"},
        ctx
      )

      assert infos(ctx) == [
               ~s(Filled 2 values in "a" with the mean, 2.0.),
               ~s(Filled 1 value in "b" with the mean, 4.0.),
               ~s(No values to fill in "c".)
             ]

      assert warnings(ctx) == []
    end

    test "Imputation warns when a column has nothing to fill from", %{ctx: ctx} do
      src = Table.sql(ctx.db, "src", "SELECT * FROM (VALUES (NULL::INTEGER), (NULL)) t(a)")
      Tools.Imputation.run(%{"in" => src}, %{"columns" => ["a"], "method" => "median"}, ctx)

      assert [warning] = warnings(ctx)

      assert warning =~
               ~s(Column "a" has no values to take the median of, so its 2 missing values stay empty.)
    end

    test "Auto Field says the type it chose for each column", %{ctx: ctx} do
      src =
        Table.new(ctx.db, "src", id: ["1", "2"], code: ["02134", "1"], when: ["2024-01-02", ""])

      Tools.AutoField.run(%{"in" => src}, %{}, ctx)

      assert infos(ctx) == [~s(Chose types: "id" BIGINT, "code" VARCHAR, "when" DATE.)]
      assert warnings(ctx) == []
    end

    test "Fuzzy Match warns when it will compare many pairs", %{ctx: ctx} do
      a = Table.sql(ctx.db, "a", "SELECT 'v' || i AS name FROM range(3200) r(i)")
      b = Table.sql(ctx.db, "b", "SELECT 'w' || i AS name FROM range(3200) r(i)")

      Tools.FuzzyMatch.run(
        %{"in" => a, "match" => b},
        %{"field" => "name", "threshold" => 100},
        ctx
      )

      assert [warning] = warnings(ctx)
      assert warning =~ "Comparing 10,240,000 pairs of records is slow."
      assert warning =~ "Filter the inputs first"
    end

    test "Fuzzy Match on a few records has no warnings", %{ctx: ctx} do
      a = Table.new(ctx.db, "a", name: ["Ada", "Adah", "Bob"])
      Tools.FuzzyMatch.run(%{"in" => a}, %{"field" => "name"}, ctx)
      assert warnings(ctx) == []
    end

    test "Generate Rows hitting its cap is an error the run reports" do
      {:ok, spec} =
        IxpipeCore.Spec.parse("""
        nodes:
          - {id: g, tool: generate_rows, config: {name: n, init: '1', condition: 'n > 0', loop: 'n + 1', max_rows: 10}}
        """)

      run = IxpipeCore.execute(spec)
      assert run.nodes == %{"g" => :failed}
      assert [%{level: :error, text: text}] = IxpipeCore.Run.messages(run, :error)
      assert text =~ "The loop reached 10 rows and its condition still held."
      assert text =~ "raise Most rows per loop"
    end
  end
end
