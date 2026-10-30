defmodule IxpipeCore.FormulaToolsTest do
  # Alteryx's formula family beyond Formula: Multi-Row Formula, Multi-Field
  # Formula and DateTime, and the function reference the editor shows.
  use ExUnit.Case, async: true
  alias IxpipeCore.{Context, Functions, Table, Tools}
  alias IxpipeCore.Tools.{DateTime, MultiFieldFormula, MultiRowFormula}

  setup do
    %{ctx: Context.new()}
  end

  defp cols(t), do: Table.to_columns(t)

  describe "multi-row formula" do
    setup %{ctx: ctx} do
      %{
        t:
          Table.new(ctx.db, "src",
            region: ["a", "a", "b", "b", "b"],
            amount: [10, 20, 30, 40, 50]
          )
      }
    end

    test "[Row-1:col] and [Row+1:col] read the previous and next rows", %{t: t, ctx: ctx} do
      out =
        MultiRowFormula.run(
          %{"in" => t},
          %{"as" => "change", "expr" => "amount - [Row-1:amount]"},
          ctx
        )

      assert Table.columns(out) == ["region", "amount", "change"]
      assert cols(out)["change"] == [nil, 10, 10, 10, 10]

      out = MultiRowFormula.run(%{"in" => t}, %{"as" => "next", "expr" => "[Row+2:amount]"}, ctx)
      assert cols(out)["next"] == [30, 40, 50, nil, nil]
    end

    test "out-of-range rows can be zero (or empty text)", %{t: t, ctx: ctx} do
      out =
        MultiRowFormula.run(
          %{"in" => t},
          %{
            "as" => "prev",
            "expr" => "[Row-1:amount] || ':' || [Row-1:region]",
            "out_of_range" => "zero"
          },
          ctx
        )

      assert cols(out)["prev"] == ["0:", "10:a", "20:a", "30:b", "40:b"]
    end

    test "groups restart the rows; an existing column is updated in place", %{t: t, ctx: ctx} do
      out =
        MultiRowFormula.run(
          %{"in" => t},
          %{
            "as" => "amount",
            "expr" => "coalesce([Row-1:amount], 0)",
            "group_by" => ["region"]
          },
          ctx
        )

      assert Table.columns(out) == ["region", "amount"]
      assert cols(out) == %{"region" => ["a", "a", "b", "b", "b"], "amount" => [0, 10, 0, 30, 40]}
    end

    test "OVER w is the group's window in row order: running totals", %{t: t, ctx: ctx} do
      out =
        MultiRowFormula.run(
          %{"in" => t},
          %{"as" => "running", "expr" => "sum(amount) OVER w", "group_by" => ["region"]},
          ctx
        )

      assert cols(out)["running"] == [10, 30, 30, 70, 120]
    end

    test "a reference to a missing column says which", %{t: t, ctx: ctx} do
      assert_raise RuntimeError, ~r/\[Row-1:nope\]: nope is not a column/, fn ->
        MultiRowFormula.run(%{"in" => t}, %{"as" => "x", "expr" => "[Row-1:nope]"}, ctx)
      end
    end

    test "translates row references to window functions" do
      assert MultiRowFormula.translate("[Row-1:a] + [row+3:b c] + [Row-0:a]", %{}) ==
               ~s{lag("a", 1) OVER w + lead("b c", 3) OVER w + "a"}
    end
  end

  describe "multi-field formula" do
    setup %{ctx: ctx} do
      %{
        t:
          Table.new(ctx.db, "src",
            name: [" ann ", "bo"],
            city: ["oslo ", " rome"],
            qty: [1, 2],
            price: [1.5, 2.5]
          )
      }
    end

    test "applies one expression to the chosen columns, in place", %{t: t, ctx: ctx} do
      out =
        MultiFieldFormula.run(
          %{"in" => t},
          %{"columns" => ["name", "city"], "expr" => "upper(trim(_current_))"},
          ctx
        )

      assert Table.columns(out) == ["name", "city", "qty", "price"]
      assert cols(out)["name"] == ["ANN", "BO"]
      assert cols(out)["city"] == ["OSLO", "ROME"]
      assert cols(out)["qty"] == [1, 2]
    end

    test "with no columns, every column of the chosen type", %{t: t, ctx: ctx} do
      out =
        MultiFieldFormula.run(
          %{"in" => t},
          %{"types" => "numeric", "expr" => "_current_ * 10"},
          ctx
        )

      assert cols(out)["qty"] == [10, 20]
      assert cols(out)["price"] == [15.0, 25.0]
      assert cols(out)["name"] == [" ann ", "bo"]
    end

    test "adds new columns with a prefix or suffix", %{t: t, ctx: ctx} do
      out =
        MultiFieldFormula.run(
          %{"in" => t},
          %{
            "columns" => ["qty", "price"],
            "expr" => "_current_name_ || '=' || _current_",
            "mode" => "add",
            "prefix" => "label_"
          },
          ctx
        )

      assert Table.columns(out) == ["name", "city", "qty", "price", "label_qty", "label_price"]
      assert cols(out)["label_qty"] == ["qty=1", "qty=2"]
      assert cols(out)["qty"] == [1, 2]

      out =
        MultiFieldFormula.run(
          %{"in" => t},
          %{"columns" => ["qty"], "expr" => "[_CurrentField_] + 1", "mode" => "add"},
          ctx
        )

      assert cols(out)["qty_new"] == [2, 3]
    end

    test "a missing column says which", %{t: t, ctx: ctx} do
      assert_raise RuntimeError, ~r/nope is not a column/, fn ->
        MultiFieldFormula.run(%{"in" => t}, %{"columns" => ["nope"], "expr" => "_current_"}, ctx)
      end
    end
  end

  describe "date time" do
    test "maps Alteryx-style formats to strptime" do
      assert DateTime.strftime("yyyy-MM-dd") == "%Y-%m-%d"
      assert DateTime.strftime("dd/MM/yyyy") == "%d/%m/%Y"
      assert DateTime.strftime("MM-dd-yyyy HH:mm:ss") == "%m-%d-%Y %H:%M:%S"
      assert DateTime.strftime("d MMM yy hh:mm tt") == "%-d %b %y %I:%M %p"
      assert DateTime.strftime("dddd, MMMM d") == "%A, %B %-d"
      assert DateTime.strftime("100% yyyy") == "100%% %Y"
      # A format that is already DuckDB's passes through.
      assert DateTime.strftime("%Y/%m/%d") == "%Y/%m/%d"
    end

    test "parses text to dates; a failed parse is NULL and goes to failed", %{ctx: ctx} do
      t =
        Table.new(ctx.db, "src",
          id: [1, 2, 3, 4],
          day: ["2024-03-05", "05/03/2024", nil, "2024-12-31"]
        )

      %{"out" => out, "failed" => failed} =
        DateTime.run(%{"in" => t}, %{"column" => "day", "format" => "yyyy-MM-dd"}, ctx)

      assert Table.columns(out) == ["id", "day", "day_date"]
      assert cols(out)["day_date"] == [~D[2024-03-05], nil, nil, ~D[2024-12-31]]
      # A NULL in is not a failure.
      assert cols(failed)["id"] == [2]
    end

    test "parses day-first dates and timestamps into a named column", %{ctx: ctx} do
      t = Table.new(ctx.db, "src", day: ["05/03/2024"], at: ["03-05-2024 14:30:00"])

      %{"out" => out} =
        DateTime.run(
          %{"in" => t},
          %{"column" => "day", "format" => "dd/MM/yyyy", "as" => "d"},
          ctx
        )

      assert cols(out)["d"] == [~D[2024-03-05]]

      %{"out" => out} =
        DateTime.run(%{"in" => t}, %{"column" => "at", "format" => "MM-dd-yyyy HH:mm:ss"}, ctx)

      assert cols(out)["at_date"] == [~N[2024-03-05 14:30:00.000000]]
    end

    test "formats dates back to text", %{ctx: ctx} do
      t = Table.new(ctx.db, "src", day: [~D[2024-03-05], nil])

      %{"out" => out, "failed" => failed} =
        DateTime.run(
          %{"in" => t},
          %{"column" => "day", "convert" => "format", "format" => "dd MMM yyyy"},
          ctx
        )

      assert cols(out)["day_text"] == ["05 Mar 2024", nil]
      assert Table.count(failed) == 0
    end
  end

  describe "function reference" do
    test "groups functions by category, each with a signature, description and example" do
      assert Functions.categories() == ~w(string math date conditional conversion)

      for f <- Functions.all() do
        assert f.category in Functions.categories(), f.name
        assert String.downcase(f.signature) =~ f.name, f.name
        assert is_binary(f.description) and f.description != "", f.name
        assert is_binary(f.example), f.name
      end

      for c <- Functions.categories(), do: assert(length(Functions.search("", c)) >= 5, c)
    end

    test "every example runs in DuckDB and gives its result", %{ctx: ctx} do
      for f <- Functions.all() do
        assert {:ok, %{rows: [[value]]}} =
                 IxpipeCore.Duck.query(ctx.db, "SELECT CAST((#{f.example}) AS VARCHAR)"),
               f.name

        assert value == f.result, "#{f.name}: #{f.example} gave #{inspect(value)}"
      end
    end

    test "search matches names and descriptions, in a category or all" do
      assert Enum.any?(Functions.search("upp", nil), &(&1.name == "upper"))
      assert Enum.all?(Functions.search("", "math"), &(&1.category == "math"))
      assert Functions.search("upper", "math") == []
      assert Enum.any?(Functions.search("capital", nil), &(&1.name == "upper"))
    end

    test "completes the word being typed" do
      assert "upper" in Enum.map(Functions.complete("trim(upp"), & &1.name)
      assert Functions.complete("amount + ") == []
      assert Functions.complete("x") |> length() <= 5
    end
  end

  test "the formula tools are registered" do
    assert Tools.lookup("multi_row_formula") == MultiRowFormula
    assert Tools.lookup("multi_field_formula") == MultiFieldFormula
    assert Tools.lookup("date_time") == DateTime
    assert Tools.outputs(DateTime) == ["out", "failed"]
  end
end
