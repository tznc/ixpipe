defmodule IxpipeCore.SelectTest do
  # Select, as in Alteryx: per column keep or drop, rename, change type and
  # reorder, plus what to do with columns the config does not list.
  use ExUnit.Case, async: true
  alias IxpipeCore.{Context, Table}
  alias IxpipeCore.Tools.Select

  setup do
    ctx = Context.new("sel")

    t =
      Table.new(ctx.db, "src",
        id: [1, 2, 3],
        amount: ["10", "x", "2.5"],
        name: ["a", "b", nil]
      )

    %{ctx: ctx, t: t}
  end

  defp run(t, config, ctx), do: Select.run(%{"in" => t}, config, ctx)

  test "a plain list of names keeps those columns, in order, as before", %{ctx: ctx, t: t} do
    out = run(t, %{"columns" => ["name", "id"]}, ctx)
    assert Table.columns(out) == ["name", "id"]
    assert out.warnings == []
  end

  test "drops, renames and reorders", %{ctx: ctx, t: t} do
    config = %{
      "columns" => [
        %{"name" => "name", "rename" => "who"},
        %{"name" => "amount", "keep" => false},
        %{"name" => "id"}
      ]
    }

    out = run(t, config, ctx)
    assert Table.columns(out) == ["who", "id"]
    assert Table.to_columns(out)["who"] == ["a", "b", nil]
  end

  test "changes types; a failed cast is NULL, and the count is a warning", %{ctx: ctx, t: t} do
    config = %{
      "columns" => [
        %{"name" => "id", "type" => "VARCHAR"},
        %{"name" => "amount", "type" => "DOUBLE"},
        %{"name" => "name", "type" => "decimal(10, 2)"}
      ]
    }

    out = run(t, config, ctx)
    assert Table.dtypes(out)["id"] == "VARCHAR"
    assert Table.dtypes(out)["amount"] == "DOUBLE"
    assert Table.dtypes(out)["name"] == "DECIMAL(10,2)"
    assert Table.to_columns(out)["amount"] == [10.0, nil, 2.5]

    assert out.warnings == [
             "amount: 1 value couldn't become DOUBLE and is now NULL.",
             "name: 2 values couldn't become DECIMAL(10, 2) and are now NULL."
           ]
  end

  test "new columns are kept, after the listed ones, by default", %{ctx: ctx, t: t} do
    out = run(t, %{"columns" => [%{"name" => "name"}, %{"name" => "id", "keep" => false}]}, ctx)
    assert Table.columns(out) == ["name", "amount"]
  end

  test "new columns can be dropped", %{ctx: ctx, t: t} do
    config = %{"columns" => [%{"name" => "name"}], "new_columns" => "drop"}
    assert Table.columns(run(t, config, ctx)) == ["name"]
  end

  test "a plain list drops new columns unless told otherwise", %{ctx: ctx, t: t} do
    assert Select.new_columns(%{"columns" => ["id"]}) == "drop"
    assert Select.new_columns(%{"columns" => [%{"name" => "id"}]}) == "keep"
    assert Select.new_columns(%{}) == "keep"
    config = %{"columns" => ["id"], "new_columns" => "keep"}
    assert Table.columns(run(t, config, ctx)) == ["id", "amount", "name"]
  end

  test "without config every column passes through", %{ctx: ctx, t: t} do
    assert Table.columns(run(t, %{}, ctx)) == ["id", "amount", "name"]
  end

  test "a listed column missing from the input is skipped with a warning", %{ctx: ctx, t: t} do
    out = run(t, %{"columns" => ["id", "gone"]}, ctx)
    assert Table.columns(out) == ["id"]
    assert out.warnings == ["gone is not in the input, so it was skipped."]
  end

  test "bad config fails the node with what to do", %{ctx: ctx, t: t} do
    assert_raise RuntimeError, ~r/FOO is not a type/, fn ->
      run(t, %{"columns" => [%{"name" => "id", "type" => "FOO"}]}, ctx)
    end

    assert_raise RuntimeError, ~r/Two columns are named id/, fn ->
      run(t, %{"columns" => [%{"name" => "id"}, %{"name" => "name", "rename" => "id"}]}, ctx)
    end

    assert_raise RuntimeError, ~r/No columns are kept/, fn ->
      run(t, %{"columns" => ["gone"]}, ctx)
    end
  end

  test "types are checked against an allow-list, so config can't inject SQL" do
    assert Select.type?("BIGINT")
    assert Select.type?("decimal(18,2)")
    assert Select.type?("TIMESTAMP")
    refute Select.type?("BIGINT); DROP TABLE x; --")
    refute Select.type?("")
  end

  describe "the editor's rows" do
    @schema [{"id", "BIGINT"}, {"amount", "VARCHAR"}, {"name", "VARCHAR"}]

    test "with no config, one kept row per input column" do
      assert [
               %{"name" => "id", "keep" => true, "input_type" => "BIGINT", "new" => true},
               %{"name" => "amount"},
               %{"name" => "name"}
             ] = Select.rows(%{}, @schema)
    end

    test "listed columns first, then new ones following the policy, missing marked" do
      config = %{"columns" => ["name", "gone"]}

      assert [
               %{"name" => "name", "keep" => true, "new" => false, "missing" => false},
               %{"name" => "gone", "keep" => true, "missing" => true, "input_type" => nil},
               %{"name" => "id", "keep" => false, "new" => true},
               %{"name" => "amount", "keep" => false, "new" => true}
             ] = Select.rows(config, @schema)
    end

    test "edits write the whole list out explicitly, keeping the policy" do
      config = Select.edit(%{"columns" => ["name"]}, @schema, 2, %{"keep" => true})

      assert config == %{
               "columns" => [
                 %{"name" => "name"},
                 %{"name" => "id", "keep" => false},
                 %{"name" => "amount"}
               ],
               "new_columns" => "drop"
             }
    end

    test "rename and type: the original name or type clears them" do
      config = Select.edit(%{}, @schema, 0, %{"rename" => "key", "type" => "VARCHAR"})
      assert hd(config["columns"]) == %{"name" => "id", "rename" => "key", "type" => "VARCHAR"}

      config = Select.edit(config, @schema, 0, %{"rename" => "id", "type" => "BIGINT"})
      assert hd(config["columns"]) == %{"name" => "id"}
    end

    test "move swaps a row with its neighbour, and stops at the ends" do
      config = Select.move(%{}, @schema, 0, 1)
      assert Enum.map(config["columns"], & &1["name"]) == ["amount", "id", "name"]
      assert Select.move(config, @schema, 0, -1) == config
      assert Select.move(config, @schema, 2, 1) == config
    end
  end
end
