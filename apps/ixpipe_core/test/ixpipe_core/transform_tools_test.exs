defmodule IxpipeCore.TransformToolsTest do
  # Alteryx's reshaping and parsing tools: Cross Tab, Transpose, Text To
  # Columns, RegEx and Data Cleansing.
  use ExUnit.Case, async: true
  alias IxpipeCore.{Context, Table, Tools}
  alias IxpipeCore.Tools.{CrossTab, DataCleansing, Regex, TextToColumns, Transpose}

  setup do
    %{ctx: Context.new()}
  end

  defp cols(t), do: Table.to_columns(t)

  defp sorted(t, by) do
    order = Enum.map_join(by, ", ", &IxpipeCore.Duck.ident/1)
    t.db |> Table.sql("sorted", "SELECT * FROM #{Table.ref(t)} ORDER BY #{order}") |> cols()
  end

  describe "cross tab" do
    setup %{ctx: ctx} do
      %{
        t:
          Table.new(ctx.db, "src",
            region: ["N", "N", "S", "S", "N"],
            month: ["jan", "feb", "jan", "feb", "jan"],
            sales: [1, 2, 3, 4, 5]
          )
      }
    end

    test "turns a column's values into columns, summing by default", %{t: t, ctx: ctx} do
      out =
        CrossTab.run(
          %{"in" => t},
          %{"group_by" => ["region"], "header" => "month", "value" => "sales"},
          ctx
        )

      assert Enum.sort(Table.columns(out)) == ["feb", "jan", "region"]

      # DuckDB's sum of a BIGINT is a HUGEINT; the values still come back as integers.
      assert sorted(out, ["region"]) == %{
               "region" => ["N", "S"],
               "jan" => [6, 3],
               "feb" => [2, 4]
             }
    end

    test "aggregates with the chosen method; missing cells are empty", %{t: t, ctx: ctx} do
      Table.exec!(ctx.db, "INSERT INTO #{Table.ref(t)} VALUES ('E', 'jan', 9)")

      out =
        CrossTab.run(
          %{"in" => t},
          %{
            "group_by" => ["region"],
            "header" => "month",
            "value" => "sales",
            "method" => "count"
          },
          ctx
        )

      assert sorted(out, ["region"]) == %{
               "region" => ["E", "N", "S"],
               "jan" => [1, 2, 1],
               "feb" => [nil, 1, 1]
             }
    end

    test "numeric header values become column names", %{ctx: ctx} do
      t = Table.new(ctx.db, "src", id: [1, 1], year: [2024, 2025], v: [1.5, 2.5])

      out =
        CrossTab.run(
          %{"in" => t},
          %{"group_by" => ["id"], "header" => "year", "value" => "v"},
          ctx
        )

      assert cols(out) == %{"id" => [1], "2024" => [1.5], "2025" => [2.5]}
    end
  end

  describe "transpose" do
    test "turns columns into name and value rows, keeping the key columns", %{ctx: ctx} do
      t = Table.new(ctx.db, "src", id: [1, 2], q1: [10, 20], q2: [30, 40])
      out = Transpose.run(%{"in" => t}, %{"keys" => ["id"]}, ctx)

      assert Table.columns(out) == ["id", "name", "value"]

      assert sorted(out, ["id", "name"]) == %{
               "id" => [1, 1, 2, 2],
               "name" => ["q1", "q2", "q1", "q2"],
               "value" => [10, 30, 20, 40]
             }
    end

    test "only the chosen data columns; mixed types become text", %{ctx: ctx} do
      t = Table.new(ctx.db, "src", id: [1], city: ["Oslo"], pop: [700], area: [454.0])
      out = Transpose.run(%{"in" => t}, %{"keys" => ["id"], "columns" => ["city", "pop"]}, ctx)

      assert cols(out) == %{
               "id" => [1, 1],
               "name" => ["city", "pop"],
               "value" => ["Oslo", "700"]
             }
    end
  end

  describe "text to columns" do
    setup %{ctx: ctx} do
      %{
        t:
          Table.new(ctx.db, "src",
            id: [1, 2, 3],
            name: ["Ada Lovelace", "Bob", "Grace Brewster Hopper"]
          )
      }
    end

    test "splits into as many columns as the most parts", %{t: t, ctx: ctx} do
      out = TextToColumns.run(%{"in" => t}, %{"column" => "name", "delimiter" => " "}, ctx)
      assert Table.columns(out) == ["id", "name", "name_1", "name_2", "name_3"]
      cols = cols(out)
      assert cols["name_1"] == ["Ada", "Bob", "Grace"]
      assert cols["name_2"] == ["Lovelace", nil, "Brewster"]
      assert cols["name_3"] == [nil, nil, "Hopper"]
    end

    test "a column count keeps the rest in the last column", %{t: t, ctx: ctx} do
      out =
        TextToColumns.run(
          %{"in" => t},
          %{"column" => "name", "delimiter" => " ", "columns" => 2},
          ctx
        )

      assert cols(out)["name_2"] == ["Lovelace", nil, "Brewster Hopper"]
      refute "name_3" in Table.columns(out)
    end

    test "splits into rows", %{t: t, ctx: ctx} do
      out =
        TextToColumns.run(
          %{"in" => t},
          %{"column" => "name", "delimiter" => " ", "split_to" => "rows"},
          ctx
        )

      assert cols(out) == %{
               "id" => [1, 1, 2, 3, 3, 3],
               "name" => ["Ada", "Lovelace", "Bob", "Grace", "Brewster", "Hopper"]
             }
    end

    test "nulls stay null", %{ctx: ctx} do
      t = Table.new(ctx.db, "src", name: ["a,b", nil])
      out = TextToColumns.run(%{"in" => t}, %{"column" => "name", "delimiter" => ","}, ctx)

      assert cols(out) == %{
               "name" => ["a,b", nil],
               "name_1" => ["a", nil],
               "name_2" => ["b", nil]
             }
    end
  end

  describe "regex" do
    setup %{ctx: ctx} do
      %{t: Table.new(ctx.db, "src", email: ["ada@x.com", "bob@y.org", "nope"])}
    end

    test "parses named groups into columns", %{t: t, ctx: ctx} do
      out =
        Regex.run(
          %{"in" => t},
          %{"column" => "email", "pattern" => "(?<user>[^@]+)@(?<domain>.+)"},
          ctx
        )

      assert Table.columns(out) == ["email", "user", "domain"]
      cols = cols(out)
      assert cols["user"] == ["ada", "bob", nil]
      assert cols["domain"] == ["x.com", "y.org", nil]
    end

    test "names unnamed groups after the column", %{t: t, ctx: ctx} do
      out = Regex.run(%{"in" => t}, %{"column" => "email", "pattern" => "([^@]+)@(.+)"}, ctx)
      assert Table.columns(out) == ["email", "email_1", "email_2"]
      assert cols(out)["email_2"] == ["x.com", "y.org", nil]
    end

    test "matches the whole value", %{t: t, ctx: ctx} do
      out =
        Regex.run(
          %{"in" => t},
          %{"column" => "email", "pattern" => ".+@.+", "mode" => "match"},
          ctx
        )

      assert cols(out)["email_matched"] == [true, true, false]

      out =
        Regex.run(%{"in" => t}, %{"column" => "email", "pattern" => "@", "mode" => "match"}, ctx)

      assert cols(out)["email_matched"] == [false, false, false]
    end

    test "replaces matches", %{t: t, ctx: ctx} do
      out =
        Regex.run(
          %{"in" => t},
          %{"column" => "email", "pattern" => "@.*", "mode" => "replace", "replacement" => ""},
          ctx
        )

      assert cols(out)["email"] == ["ada", "bob", "nope"]
    end

    test "replacements refer to groups with $1", %{t: t, ctx: ctx} do
      out =
        Regex.run(
          %{"in" => t},
          %{
            "column" => "email",
            "pattern" => "(\\w+)@(\\w+)",
            "mode" => "replace",
            "replacement" => "$2 at $1"
          },
          ctx
        )

      assert cols(out)["email"] == ["x at ada.com", "y at bob.org", "nope"]
    end

    test "says when the pattern is wrong", %{t: t, ctx: ctx} do
      for mode <- ~w(parse match replace) do
        assert_raise RuntimeError, ~r/Invalid pattern/, fn ->
          Regex.run(
            %{"in" => t},
            %{"column" => "email", "pattern" => "(unclosed", "mode" => mode},
            ctx
          )
        end
      end
    end
  end

  describe "data cleansing" do
    setup %{ctx: ctx} do
      %{
        t:
          Table.new(ctx.db, "src",
            name: ["  ada  ", nil, "bob\t  smith", nil],
            n: [1, 2, 3, nil]
          )
      }
    end

    test "by default trims text, and keeps nulls and rows", %{t: t, ctx: ctx} do
      out = DataCleansing.run(%{"in" => t}, %{}, ctx)

      assert cols(out) == %{
               "name" => ["ada", nil, "bob\t  smith", nil],
               "n" => [1, 2, 3, nil]
             }
    end

    test "every option", %{t: t, ctx: ctx} do
      out =
        DataCleansing.run(
          %{"in" => t},
          %{
            "remove_null_rows" => true,
            "replace_nulls" => true,
            "collapse_whitespace" => true,
            "case" => "title"
          },
          ctx
        )

      assert cols(out) == %{"name" => ["Ada", "", "Bob Smith"], "n" => [1, 2, 3]}
    end

    test "title case capitalises each word", %{ctx: ctx} do
      t = Table.new(ctx.db, "src", name: ["mARY-jane o'neil", "élan  vital"])
      out = DataCleansing.run(%{"in" => t}, %{"case" => "title"}, ctx)
      assert cols(out)["name"] == ["Mary-Jane O'Neil", "Élan  Vital"]
    end

    test "only the chosen columns", %{t: t, ctx: ctx} do
      out = DataCleansing.run(%{"in" => t}, %{"columns" => ["n"], "replace_nulls" => true}, ctx)
      assert cols(out)["name"] == ["  ada  ", nil, "bob\t  smith", nil]
      assert cols(out)["n"] == [1, 2, 3, 0]
    end

    test "upper and lower case", %{t: t, ctx: ctx} do
      assert cols(DataCleansing.run(%{"in" => t}, %{"case" => "upper"}, ctx))["name"] ==
               ["ADA", nil, "BOB\t  SMITH", nil]

      assert cols(DataCleansing.run(%{"in" => t}, %{"case" => "lower"}, ctx))["name"] ==
               ["ada", nil, "bob\t  smith", nil]
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

    assert {:ok, %{"wide" => t}} = IxpipeCore.run(spec)
    assert Table.count(t) == 3 and "customer_id" in Table.columns(t)
  end
end
