defmodule IxpipeCore.EverydayToolsTest do
  # Alteryx's everyday preparation and join tools: Record ID, Running Total,
  # Tile, Generate Rows, Imputation, Auto Field, Find Replace, Append
  # Fields, Join Multiple and Fuzzy Match.
  use ExUnit.Case, async: true
  alias IxpipeCore.{Context, Table}

  alias IxpipeCore.Tools.{
    AppendFields,
    AutoField,
    FindReplace,
    FuzzyMatch,
    GenerateRows,
    Imputation,
    JoinMultiple,
    RecordId,
    RunningTotal,
    Tile
  }

  setup do
    %{ctx: Context.new()}
  end

  defp cols(t), do: Table.to_columns(t)
  defp src(ctx, name \\ "src", columns), do: Table.new(ctx.db, name, columns)

  describe "record id" do
    test "numbers the rows from 1 in a first column by default", %{ctx: ctx} do
      t = src(ctx, name: ["a", "b", "c"])
      out = RecordId.run(%{"in" => t}, %{}, ctx)
      assert Table.columns(out) == ["RecordID", "name"]
      assert cols(out)["RecordID"] == [1, 2, 3]
    end

    test "takes a name, a start value and a last position", %{ctx: ctx} do
      t = src(ctx, name: ["a", "b"])

      out =
        RecordId.run(%{"in" => t}, %{"name" => "id", "start" => 100, "position" => "last"}, ctx)

      assert Table.columns(out) == ["name", "id"]
      assert cols(out) == %{"name" => ["a", "b"], "id" => [100, 101]}
    end
  end

  describe "running total" do
    test "sums each chosen column down the rows", %{ctx: ctx} do
      t = src(ctx, x: [1, 2, 3], y: [1.5, nil, 2.0])
      out = RunningTotal.run(%{"in" => t}, %{"columns" => ["x", "y"]}, ctx)
      assert cols(out)["RunningTotal_x"] == [1, 3, 6]
      assert cols(out)["RunningTotal_y"] == [1.5, 1.5, 3.5]
    end

    test "restarts for each group, keeping row order", %{ctx: ctx} do
      t = src(ctx, g: ["a", "b", "a", "b"], x: [1, 10, 2, 20])
      out = RunningTotal.run(%{"in" => t}, %{"columns" => ["x"], "group_by" => ["g"]}, ctx)
      assert cols(out)["g"] == ["a", "b", "a", "b"]
      assert cols(out)["RunningTotal_x"] == [1, 10, 3, 30]
    end
  end

  describe "tile" do
    test "equal records splits rows in order into n tiles", %{ctx: ctx} do
      t = src(ctx, x: [5, 4, 3, 2, 1, 0])
      out = Tile.run(%{"in" => t}, %{"method" => "equal_records", "tiles" => 3}, ctx)
      assert cols(out)["x"] == [5, 4, 3, 2, 1, 0]
      assert cols(out)["Tile_Num"] == [1, 1, 2, 2, 3, 3]
      assert cols(out)["Tile_SequenceNum"] == [1, 2, 1, 2, 1, 2]
    end

    test "equal records sorted by a column, per group", %{ctx: ctx} do
      t = src(ctx, g: ["a", "a", "b", "b"], x: [2, 1, 1, 2])

      out =
        Tile.run(
          %{"in" => t},
          %{"method" => "equal_records", "tiles" => 2, "column" => "x", "group_by" => ["g"]},
          ctx
        )

      assert cols(out)["Tile_Num"] == [2, 1, 1, 2]
    end

    test "equal sum gives each tile about the same total", %{ctx: ctx} do
      t = src(ctx, x: [10, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1])
      out = Tile.run(%{"in" => t}, %{"method" => "equal_sum", "tiles" => 2, "column" => "x"}, ctx)
      # Sorted ascending, the ten 1s fill tile 1 and the 10 tile 2.
      assert cols(out)["Tile_Num"] == [2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
    end

    test "manual cut-offs: tile 1 is up to the first cut-off", %{ctx: ctx} do
      t = src(ctx, x: [1, 10, 11, 50, 100])

      out =
        Tile.run(
          %{"in" => t},
          %{"method" => "manual", "column" => "x", "cutoffs" => ["10", "50"]},
          ctx
        )

      assert cols(out)["Tile_Num"] == [1, 1, 2, 2, 3]
    end

    test "smart tiles by standard deviations from the mean, with a name", %{ctx: ctx} do
      t = src(ctx, x: [0, 10, 10, 10, 10, 10, 10, 10, 10, 20])
      out = Tile.run(%{"in" => t}, %{"method" => "smart", "column" => "x"}, ctx)
      # mean 10, sample sd ~4.7: 0 and 20 are just over two sd out.
      assert cols(out)["Tile_Num"] == [-2, 0, 0, 0, 0, 0, 0, 0, 0, 2]
      assert hd(cols(out)["Tile_Name"]) == "Low"
      assert Enum.at(cols(out)["Tile_Name"], 1) == "Average"
    end

    test "a method that needs a column says so", %{ctx: ctx} do
      t = src(ctx, x: [1])

      assert_raise RuntimeError, ~r/needs a column/, fn ->
        Tile.run(%{"in" => t}, %{"method" => "smart"}, ctx)
      end
    end
  end

  describe "generate rows" do
    test "as a source, loops from the initial value while the condition holds", %{ctx: ctx} do
      out =
        GenerateRows.run(
          %{},
          %{"name" => "n", "init" => "1", "condition" => "n <= 5", "loop" => "n + 2"},
          ctx
        )

      assert cols(out) == %{"n" => [1, 3, 5]}
    end

    test "per input row, from that row's columns", %{ctx: ctx} do
      t = src(ctx, id: ["a", "b"], lo: [1, 5], hi: [3, 5])

      out =
        GenerateRows.run(
          %{"in" => t},
          %{"name" => "n", "init" => "lo", "condition" => "n <= hi", "loop" => "n + 1"},
          ctx
        )

      assert Table.columns(out) == ["id", "lo", "hi", "n"]
      assert cols(out)["id"] == ["a", "a", "a", "b"]
      assert cols(out)["n"] == [1, 2, 3, 5]
    end

    test "dates step by intervals", %{ctx: ctx} do
      out =
        GenerateRows.run(
          %{},
          %{
            "name" => "day",
            "init" => "DATE '2026-01-30'",
            "condition" => "day <= DATE '2026-02-01'",
            "loop" => "day + 1"
          },
          ctx
        )

      assert cols(out)["day"] == [~D[2026-01-30], ~D[2026-01-31], ~D[2026-02-01]]
    end

    test "stops with an error at the row cap", %{ctx: ctx} do
      config = %{
        "name" => "n",
        "init" => "1",
        "condition" => "true",
        "loop" => "n + 1",
        "max_rows" => 50
      }

      assert_raise RuntimeError, ~r/50 rows/, fn -> GenerateRows.run(%{}, config, ctx) end
    end
  end

  describe "imputation" do
    setup %{ctx: ctx} do
      %{t: src(ctx, x: [1, nil, 3, 3, nil], y: [2.0, 4.0, nil, 4.0, 0.0])}
    end

    test "fills nulls with the mean", %{t: t, ctx: ctx} do
      out = Imputation.run(%{"in" => t}, %{"columns" => ["x", "y"], "method" => "mean"}, ctx)
      x = cols(out)["x"]
      assert Enum.map(x, &round(&1 * 1000)) == [1000, 2333, 3000, 3000, 2333]
      assert cols(out)["y"] == [2.0, 4.0, 2.5, 4.0, 0.0]
    end

    test "median, mode and a constant", %{t: t, ctx: ctx} do
      median = Imputation.run(%{"in" => t}, %{"columns" => ["x"], "method" => "median"}, ctx)
      assert cols(median)["x"] == [1.0, 3.0, 3.0, 3.0, 3.0]

      mode = Imputation.run(%{"in" => t}, %{"columns" => ["y"], "method" => "mode"}, ctx)
      assert cols(mode)["y"] == [2.0, 4.0, 4.0, 4.0, 0.0]

      constant =
        Imputation.run(
          %{"in" => t},
          %{"columns" => ["x"], "method" => "constant", "value" => "-1"},
          ctx
        )

      assert cols(constant)["x"] == [1.0, -1.0, 3.0, 3.0, -1.0]
    end

    test "replaces a chosen value instead, with an indicator column", %{t: t, ctx: ctx} do
      out =
        Imputation.run(
          %{"in" => t},
          %{"columns" => ["y"], "method" => "mean", "missing" => "0", "indicator" => true},
          ctx
        )

      # The mean of the values other than 0 (nulls aside): 10 / 3.
      assert Enum.map(cols(out)["y"], &(&1 && Float.round(&1, 2))) == [2.0, 4.0, nil, 4.0, 3.33]
      assert cols(out)["y_imputed"] == [false, false, false, false, true]
    end

    test "refuses a text column", %{ctx: ctx} do
      t = src(ctx, s: ["a", nil])

      assert_raise RuntimeError, ~r/s is not numeric/, fn ->
        Imputation.run(%{"in" => t}, %{"columns" => ["s"], "method" => "mean"}, ctx)
      end
    end
  end

  describe "auto field" do
    test "gives each text column the narrowest type that fits", %{ctx: ctx} do
      t =
        src(ctx,
          int: ["1", " 2", nil, ""],
          dbl: ["1", "2.5", "-3e2", nil],
          date: ["2026-01-02", "2025-12-31", nil, nil],
          ts: ["2026-01-02 10:00:00", "2026-01-02", nil, nil],
          bool: ["true", "false", "TRUE", nil],
          text: ["1", "x", nil, nil],
          zip: ["02134", "90210", nil, nil],
          empty: [nil, nil, nil, nil],
          n: [1, 2, 3, 4]
        )

      out = AutoField.run(%{"in" => t}, %{}, ctx)

      assert Table.dtypes(out) == %{
               "int" => "BIGINT",
               "dbl" => "DOUBLE",
               "date" => "DATE",
               "ts" => "TIMESTAMP",
               "bool" => "BOOLEAN",
               "text" => "VARCHAR",
               "zip" => "VARCHAR",
               "empty" => "VARCHAR",
               "n" => "BIGINT"
             }

      assert Table.columns(out) == Table.columns(t)
      assert cols(out)["int"] == [1, 2, nil, nil]
      assert cols(out)["dbl"] == [1.0, 2.5, -300.0, nil]
      assert cols(out)["zip"] == ["02134", "90210", nil, nil]
    end

    test "only the chosen columns", %{ctx: ctx} do
      t = src(ctx, a: ["1"], b: ["2"])
      out = AutoField.run(%{"in" => t}, %{"columns" => ["b"]}, ctx)
      assert Table.dtypes(out) == %{"a" => "VARCHAR", "b" => "BIGINT"}
    end
  end

  describe "find replace" do
    setup %{ctx: ctx} do
      %{
        t: src(ctx, "t", id: [1, 2, 3, 4], city: ["NYC", "nyc", "SF Bay", nil]),
        lookup:
          src(ctx, "lookup",
            code: ["NYC", "SF", ""],
            name: ["New York", "San Francisco", "Nowhere"],
            state: ["NY", "CA", "XX"]
          )
      }
    end

    test "replaces a whole field that matches", %{t: t, lookup: lookup, ctx: ctx} do
      out =
        FindReplace.run(
          %{"in" => t, "lookup" => lookup},
          %{"field" => "city", "find" => "code", "replace" => "name"},
          ctx
        )

      assert cols(out) == %{"id" => [1, 2, 3, 4], "city" => ["New York", "nyc", "SF Bay", nil]}
    end

    test "case-insensitive, any part of the field", %{t: t, lookup: lookup, ctx: ctx} do
      out =
        FindReplace.run(
          %{"in" => t, "lookup" => lookup},
          %{
            "field" => "city",
            "find" => "code",
            "replace" => "name",
            "match" => "any_part",
            "case_insensitive" => true
          },
          ctx
        )

      assert cols(out)["city"] == ["New York", "New York", "San Francisco Bay", nil]
    end

    test "appends lookup columns of the first match", %{t: t, lookup: lookup, ctx: ctx} do
      out =
        FindReplace.run(
          %{"in" => t, "lookup" => lookup},
          %{
            "field" => "city",
            "find" => "code",
            "action" => "append",
            "append" => ["state", "name"],
            "match" => "any_part"
          },
          ctx
        )

      assert Table.columns(out) == ["id", "city", "state", "name"]
      assert cols(out)["state"] == ["NY", nil, "CA", nil]
      assert cols(out)["city"] == ["NYC", "nyc", "SF Bay", nil]
    end

    test "replace needs a replacement column", %{t: t, lookup: lookup, ctx: ctx} do
      assert_raise RuntimeError, ~r/Choose the lookup column/, fn ->
        FindReplace.run(
          %{"in" => t, "lookup" => lookup},
          %{"field" => "city", "find" => "code"},
          ctx
        )
      end
    end
  end

  describe "append fields" do
    setup %{ctx: ctx} do
      %{
        target: src(ctx, "target", id: [1, 2], v: ["a", "b"]),
        source: src(ctx, "source", v: ["x", "y"], rate: [0.1, 0.2])
      }
    end

    test "appends every source row to every target row", %{target: t, source: s, ctx: ctx} do
      out = AppendFields.run(%{"target" => t, "source" => s}, %{}, ctx)
      assert Table.columns(out) == ["id", "v", "Source_v", "rate"]

      assert cols(out) == %{
               "id" => [1, 1, 2, 2],
               "v" => ["a", "a", "b", "b"],
               "Source_v" => ["x", "y", "x", "y"],
               "rate" => [0.1, 0.2, 0.1, 0.2]
             }
    end

    test "errors on a source over the limit, unless told otherwise", %{
      target: t,
      source: s,
      ctx: ctx
    } do
      assert_raise RuntimeError, ~r/2 rows.*limit of 1/, fn ->
        AppendFields.run(%{"target" => t, "source" => s}, %{"limit" => 1}, ctx)
      end

      warn =
        AppendFields.run(
          %{"target" => t, "source" => s},
          %{"limit" => 1, "too_many" => "warn"},
          ctx
        )

      assert Table.count(warn) == 4

      assert [%{level: :warning, text: "The source has 2 rows, over the limit of 1." <> _}] =
               Enum.filter(IxpipeCore.Context.messages(ctx), &(&1.level == :warning))

      allow =
        AppendFields.run(
          %{"target" => t, "source" => s},
          %{"limit" => 1, "too_many" => "allow"},
          ctx
        )

      assert Table.count(allow) == 4
      assert length(Enum.filter(IxpipeCore.Context.messages(ctx), &(&1.level == :warning))) == 1
    end
  end

  describe "join multiple" do
    setup %{ctx: ctx} do
      %{
        a: src(ctx, "a", k: [1, 2, 3], v: ["a1", "a2", "a3"]),
        b: src(ctx, "b", k: [1, 2], v: ["b1", "b2"]),
        c: src(ctx, "c", k: [2, 4], w: ["c2", "c4"])
      }
    end

    defp by_k(t) do
      t.db |> Table.sql("by_k", "SELECT * FROM #{Table.ref(t)} ORDER BY k") |> Table.to_columns()
    end

    test "an outer join on the key by default, suffixing repeated names", %{
      a: a,
      b: b,
      c: c,
      ctx: ctx
    } do
      out = JoinMultiple.run(%{"in1" => a, "in2" => b, "in3" => c}, %{"on" => ["k"]}, ctx)
      assert Table.columns(out) == ["k", "v", "v_in2", "w"]

      assert by_k(out) == %{
               "k" => [1, 2, 3, 4],
               "v" => ["a1", "a2", "a3", nil],
               "v_in2" => ["b1", "b2", nil, nil],
               "w" => [nil, "c2", nil, "c4"]
             }
    end

    test "inner keeps only keys in every input", %{a: a, b: b, c: c, ctx: ctx} do
      out =
        JoinMultiple.run(
          %{"in1" => a, "in2" => b, "in3" => c},
          %{"on" => ["k"], "how" => "inner"},
          ctx
        )

      assert by_k(out) == %{"k" => [2], "v" => ["a2"], "v_in2" => ["b2"], "w" => ["c2"]}
    end
  end

  describe "fuzzy match" do
    test "dedupes one input into scored pairs above the threshold", %{ctx: ctx} do
      t = src(ctx, name: ["Jon Smith", "John Smith", "Mary Jones", "Jonh Smith"])
      out = FuzzyMatch.run(%{"in" => t}, %{"field" => "name", "threshold" => 90}, ctx)

      assert Table.columns(out) == ["id", "match_id", "value", "match_value", "score"]
      c = cols(out)
      assert Enum.zip(c["id"], c["match_id"]) == [{1, 2}, {1, 4}, {2, 4}]
      assert Enum.all?(c["score"], &(&1 >= 90 and &1 <= 100))
    end

    test "matches one input against another by levenshtein, with an id column", %{ctx: ctx} do
      t = src(ctx, "t", cid: ["a", "b"], name: ["acme inc", "globex"])
      m = src(ctx, "m", cid: ["x", "y"], name: ["ACME Inc.", "initech"])

      out =
        FuzzyMatch.run(
          %{"in" => t, "match" => m},
          %{"field" => "name", "id" => "cid", "method" => "levenshtein", "threshold" => 80},
          ctx
        )

      assert cols(out) == %{
               "id" => ["a"],
               "match_id" => ["x"],
               "value" => ["acme inc"],
               "match_value" => ["ACME Inc."],
               "score" => [88.9]
             }
    end

    test "jaccard and clusters of connected matches", %{ctx: ctx} do
      t = src(ctx, name: ["abc", "abcd", "bcd", "xyz", "xyzw"])

      out =
        FuzzyMatch.run(
          %{"in" => t},
          %{"field" => "name", "method" => "jaccard", "threshold" => 60, "clusters" => true},
          ctx
        )

      c = cols(out)
      pairs = Enum.zip([c["id"], c["match_id"], c["cluster"]])
      assert {1, 2, 1} in pairs
      assert {2, 3, 1} in pairs
      assert {4, 5, 2} in pairs
    end
  end
end
