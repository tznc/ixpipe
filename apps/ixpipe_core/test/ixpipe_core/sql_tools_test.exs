defmodule IxpipeCore.SqlToolsTest do
  use ExUnit.Case, async: true
  alias Explorer.DataFrame, as: DF
  alias IxpipeCore.Tools.{Filter, Formula}

  setup do
    %{df: DF.new(id: [1, 2, 3], amount: [50, 5, 30], region: ["eu", "us", "eu"])}
  end

  describe "filter" do
    test "keeps rows matching a SQL expression", %{df: df} do
      %{"true" => out} = Filter.run(%{"in" => df}, %{"expr" => "amount > 10 AND region = 'eu'"})
      assert DF.to_columns(out)["id"] == [1, 3]
    end

    test "can reference the input as df in subqueries", %{df: df} do
      %{"true" => out} =
        Filter.run(%{"in" => df}, %{"expr" => "amount IN (SELECT MAX(amount) FROM df)"})

      assert DF.to_columns(out)["id"] == [1]
    end

    test "raises on invalid SQL", %{df: df} do
      assert_raise RuntimeError, fn -> Filter.run(%{"in" => df}, %{"expr" => "amount >"}) end
    end
  end

  describe "formula" do
    test "adds columns, each seeing the ones before it", %{df: df} do
      out =
        Formula.run(%{"in" => df}, %{
          "formulas" => [
            %{"as" => "taxed", "expr" => "amount * 2"},
            %{"as" => "size", "expr" => "CASE WHEN taxed > 50 THEN 'big' ELSE 'small' END"}
          ]
        })

      cols = DF.to_columns(out)
      assert DF.names(out) == ["id", "amount", "region", "taxed", "size"]
      assert cols["taxed"] == [100, 10, 60]
      assert cols["size"] == ["big", "small", "big"]
    end

    test "replaces an existing column in place", %{df: df} do
      out =
        Formula.run(%{"in" => df}, %{
          "formulas" => [%{"as" => "region", "expr" => "UPPER(region)"}]
        })

      assert DF.names(out) == ["id", "amount", "region"]
      assert DF.to_columns(out)["region"] == ["EU", "US", "EU"]
    end

    test "quotes output names", %{df: df} do
      out =
        Formula.run(%{"in" => df}, %{"formulas" => [%{"as" => ~s(odd "name"), "expr" => "1"}]})

      assert ~s(odd "name") in DF.names(out)
    end
  end

  test "both are registered" do
    assert IxpipeCore.Tools.lookup("filter") == Filter
    assert IxpipeCore.Tools.lookup("formula") == Formula
  end
end
