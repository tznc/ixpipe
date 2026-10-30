defmodule IxpipeCore.SqlToolsTest do
  use ExUnit.Case, async: true
  alias IxpipeCore.{Context, Table}
  alias IxpipeCore.Tools.{Filter, Formula}

  setup do
    ctx = Context.new("out")

    %{
      ctx: ctx,
      df: Table.new(ctx.db, "src", id: [1, 2, 3], amount: [50, 5, 30], region: ["eu", "us", "eu"])
    }
  end

  describe "filter" do
    test "keeps rows matching a SQL expression", %{df: df, ctx: ctx} do
      %{"true" => out} =
        Filter.run(%{"in" => df}, %{"expr" => "amount > 10 AND region = 'eu'"}, ctx)

      assert Table.to_columns(out)["id"] == [1, 3]
    end

    test "can reference the input as df in subqueries", %{df: df, ctx: ctx} do
      %{"true" => out} =
        Filter.run(%{"in" => df}, %{"expr" => "amount IN (SELECT MAX(amount) FROM df)"}, ctx)

      assert Table.to_columns(out)["id"] == [1]
    end

    test "raises on invalid SQL", %{df: df, ctx: ctx} do
      assert_raise RuntimeError, fn -> Filter.run(%{"in" => df}, %{"expr" => "amount >"}, ctx) end
    end
  end

  describe "formula" do
    test "adds columns, each seeing the ones before it", %{df: df, ctx: ctx} do
      out =
        Formula.run(
          %{"in" => df},
          %{
            "formulas" => [
              %{"as" => "taxed", "expr" => "amount * 2"},
              %{"as" => "size", "expr" => "CASE WHEN taxed > 50 THEN 'big' ELSE 'small' END"}
            ]
          },
          ctx
        )

      cols = Table.to_columns(out)
      assert Table.columns(out) == ["id", "amount", "region", "taxed", "size"]
      assert cols["taxed"] == [100, 10, 60]
      assert cols["size"] == ["big", "small", "big"]
    end

    test "replaces an existing column in place", %{df: df, ctx: ctx} do
      out =
        Formula.run(
          %{"in" => df},
          %{
            "formulas" => [%{"as" => "region", "expr" => "UPPER(region)"}]
          },
          ctx
        )

      assert Table.columns(out) == ["id", "amount", "region"]
      assert Table.to_columns(out)["region"] == ["EU", "US", "EU"]
    end

    test "quotes output names", %{df: df, ctx: ctx} do
      out =
        Formula.run(
          %{"in" => df},
          %{"formulas" => [%{"as" => ~s(odd "name"), "expr" => "1"}]},
          ctx
        )

      assert ~s(odd "name") in Table.columns(out)
    end
  end

  test "both are registered" do
    assert IxpipeCore.Tools.lookup("filter") == Filter
    assert IxpipeCore.Tools.lookup("formula") == Formula
  end
end
