defmodule IxpipeCore.TransformToolsTest do
  # Alteryx's reshaping and parsing tools: Cross Tab, Transpose, Text To
  # Columns, RegEx and Data Cleansing.
  use ExUnit.Case, async: true
  alias Explorer.DataFrame, as: DF
  alias IxpipeCore.Tools
  alias IxpipeCore.Tools.{CrossTab, DataCleansing, Regex, TextToColumns, Transpose}

  defp sorted(df, by),
    do: df |> DF.sort_with(fn ldf -> Enum.map(by, &ldf[&1]) end) |> DF.to_columns()

  describe "cross tab" do
    setup do
      %{
        df:
          DF.new(
            region: ["N", "N", "S", "S", "N"],
            month: ["jan", "feb", "jan", "feb", "jan"],
            sales: [1, 2, 3, 4, 5]
          )
      }
    end

    test "turns a column's values into columns, summing by default", %{df: df} do
      out =
        CrossTab.run(%{"in" => df}, %{
          "group_by" => ["region"],
          "header" => "month",
          "value" => "sales"
        })

      assert Enum.sort(DF.names(out)) == ["feb", "jan", "region"]

      assert sorted(out, ["region"]) == %{
               "region" => ["N", "S"],
               "jan" => [6, 3],
               "feb" => [2, 4]
             }
    end

    test "aggregates with the chosen method; missing cells are empty", %{df: df} do
      df = DF.concat_rows(df, DF.new(region: ["E"], month: ["jan"], sales: [9]))

      out =
        CrossTab.run(%{"in" => df}, %{
          "group_by" => ["region"],
          "header" => "month",
          "value" => "sales",
          "method" => "count"
        })

      assert sorted(out, ["region"]) == %{
               "region" => ["E", "N", "S"],
               "jan" => [1, 2, 1],
               "feb" => [nil, 1, 1]
             }
    end

    test "numeric header values become column names" do
      df = DF.new(id: [1, 1], year: [2024, 2025], v: [1.5, 2.5])

      out =
        CrossTab.run(%{"in" => df}, %{"group_by" => ["id"], "header" => "year", "value" => "v"})

      assert DF.to_columns(out) == %{"id" => [1], "2024" => [1.5], "2025" => [2.5]}
    end
  end

  describe "transpose" do
    test "turns columns into name and value rows, keeping the key columns" do
      df = DF.new(id: [1, 2], q1: [10, 20], q2: [30, 40])
      out = Transpose.run(%{"in" => df}, %{"keys" => ["id"]})

      assert DF.names(out) == ["id", "name", "value"]

      assert sorted(out, ["id", "name"]) == %{
               "id" => [1, 1, 2, 2],
               "name" => ["q1", "q2", "q1", "q2"],
               "value" => [10, 30, 20, 40]
             }
    end

    test "only the chosen data columns; mixed types become text" do
      df = DF.new(id: [1], city: ["Oslo"], pop: [700], area: [454.0])
      out = Transpose.run(%{"in" => df}, %{"keys" => ["id"], "columns" => ["city", "pop"]})

      assert DF.to_columns(out) == %{
               "id" => [1, 1],
               "name" => ["city", "pop"],
               "value" => ["Oslo", "700"]
             }
    end
  end

  describe "text to columns" do
    setup do
      %{df: DF.new(id: [1, 2, 3], name: ["Ada Lovelace", "Bob", "Grace Brewster Hopper"])}
    end

    test "splits into as many columns as the most parts", %{df: df} do
      out = TextToColumns.run(%{"in" => df}, %{"column" => "name", "delimiter" => " "})
      assert DF.names(out) == ["id", "name", "name_1", "name_2", "name_3"]
      cols = DF.to_columns(out)
      assert cols["name_1"] == ["Ada", "Bob", "Grace"]
      assert cols["name_2"] == ["Lovelace", nil, "Brewster"]
      assert cols["name_3"] == [nil, nil, "Hopper"]
    end

    test "a column count keeps the rest in the last column", %{df: df} do
      out =
        TextToColumns.run(%{"in" => df}, %{"column" => "name", "delimiter" => " ", "columns" => 2})

      assert DF.to_columns(out)["name_2"] == ["Lovelace", nil, "Brewster Hopper"]
      refute "name_3" in DF.names(out)
    end

    test "splits into rows", %{df: df} do
      out =
        TextToColumns.run(%{"in" => df}, %{
          "column" => "name",
          "delimiter" => " ",
          "split_to" => "rows"
        })

      assert DF.to_columns(out) == %{
               "id" => [1, 1, 2, 3, 3, 3],
               "name" => ["Ada", "Lovelace", "Bob", "Grace", "Brewster", "Hopper"]
             }
    end
  end

  describe "regex" do
    setup do
      %{df: DF.new(email: ["ada@x.com", "bob@y.org", "nope"])}
    end

    test "parses named groups into columns", %{df: df} do
      out =
        Regex.run(%{"in" => df}, %{
          "column" => "email",
          "pattern" => "(?<user>[^@]+)@(?<domain>.+)"
        })

      cols = DF.to_columns(out)
      assert cols["user"] == ["ada", "bob", nil]
      assert cols["domain"] == ["x.com", "y.org", nil]
    end

    test "names unnamed groups after the column", %{df: df} do
      out = Regex.run(%{"in" => df}, %{"column" => "email", "pattern" => "([^@]+)@(.+)"})
      assert DF.to_columns(out)["email_2"] == ["x.com", "y.org", nil]
    end

    test "matches the whole value", %{df: df} do
      out =
        Regex.run(%{"in" => df}, %{"column" => "email", "pattern" => ".+@.+", "mode" => "match"})

      assert DF.to_columns(out)["email_matched"] == [true, true, false]

      out = Regex.run(%{"in" => df}, %{"column" => "email", "pattern" => "@", "mode" => "match"})
      assert DF.to_columns(out)["email_matched"] == [false, false, false]
    end

    test "replaces matches", %{df: df} do
      out =
        Regex.run(%{"in" => df}, %{
          "column" => "email",
          "pattern" => "@.*",
          "mode" => "replace",
          "replacement" => ""
        })

      assert DF.to_columns(out)["email"] == ["ada", "bob", "nope"]
    end

    test "says when the pattern is wrong", %{df: df} do
      assert_raise RuntimeError, ~r/Invalid pattern/, fn ->
        Regex.run(%{"in" => df}, %{"column" => "email", "pattern" => "(unclosed"})
      end
    end
  end

  describe "data cleansing" do
    setup do
      %{
        df:
          DF.new(
            name: ["  ada  ", nil, "bob\t  smith", nil],
            n: [1, 2, 3, nil]
          )
      }
    end

    test "by default trims text, and keeps nulls and rows", %{df: df} do
      out = DataCleansing.run(%{"in" => df}, %{})

      assert DF.to_columns(out) == %{
               "name" => ["ada", nil, "bob\t  smith", nil],
               "n" => [1, 2, 3, nil]
             }
    end

    test "every option", %{df: df} do
      out =
        DataCleansing.run(%{"in" => df}, %{
          "remove_null_rows" => true,
          "replace_nulls" => true,
          "collapse_whitespace" => true,
          "case" => "title"
        })

      assert DF.to_columns(out) == %{"name" => ["Ada", "", "Bob Smith"], "n" => [1, 2, 3]}
    end

    test "only the chosen columns", %{df: df} do
      out = DataCleansing.run(%{"in" => df}, %{"columns" => ["n"], "replace_nulls" => true})
      assert DF.to_columns(out)["name"] == ["  ada  ", nil, "bob\t  smith", nil]
      assert DF.to_columns(out)["n"] == [1, 2, 3, 0]
    end

    test "upper and lower case", %{df: df} do
      assert DF.to_columns(DataCleansing.run(%{"in" => df}, %{"case" => "upper"}))["name"] ==
               ["ADA", nil, "BOB\t  SMITH", nil]
    end
  end

  test "the tools are registered" do
    for {name, tool} <- [
          {"cross_tab", CrossTab},
          {"transpose", Transpose},
          {"text_to_columns", TextToColumns},
          {"regex", Regex},
          {"data_cleansing", DataCleansing}
        ] do
      assert Tools.lookup(name) == tool
    end

    assert Tools.required(CrossTab) == ["group_by", "header", "value"]
    assert Tools.required(Transpose) == ["keys"]
    assert Tools.required(TextToColumns) == ["column", "delimiter"]
    assert Tools.required(Regex) == ["column", "pattern"]
    assert Tools.required(DataCleansing) == []
  end

  test "a workflow cleans, parses and cross-tabs" do
    {:ok, spec} =
      IxpipeCore.Spec.parse("""
      nodes:
        - {id: src, tool: input_csv, config: {path: #{Path.expand("../fixtures/orders.csv", __DIR__)}}}
        - {id: wide, tool: cross_tab, inputs: {in: src}, config: {group_by: [customer_id], header: id, value: amount}}
      """)

    assert {:ok, %{"wide" => df}} = IxpipeCore.run(spec)
    assert DF.n_rows(df) == 3 and "customer_id" in DF.names(df)
  end
end
