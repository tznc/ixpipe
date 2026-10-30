defmodule IxpipeCore.DuckTest do
  # DuckDB (v2, bundled): one in-memory database per run, which every
  # Runic step reaches through its own connection, and tables in it.
  use ExUnit.Case, async: true
  alias IxpipeCore.{Duck, Table}

  setup do
    {:ok, db} = Duck.open()
    %{db: db}
  end

  test "the engine is DuckDB v2", %{db: db} do
    assert {:ok, %{rows: [["v2." <> _]]}} = Duck.query(db, "SELECT version()")
  end

  test "values come back as Elixir terms", %{db: db} do
    assert {:ok, %{columns: columns, rows: [row]}} =
             Duck.query(db, """
             SELECT 1 AS i, 2.5::DOUBLE AS d, 'x' AS s, true AS b, NULL AS n,
                    DATE '2024-02-29' AS day, TIMESTAMP '2024-02-29 13:45:01.5' AS at,
                    1.25::DECIMAL(5, 2) AS dec, [1, 2] AS l, {'a': 1} AS st,
                    170141183460469231731687303715884105727::HUGEINT AS big
             """)

    assert columns == ~w(i d s b n day at dec l st big)

    assert row == [
             1,
             2.5,
             "x",
             true,
             nil,
             ~D[2024-02-29],
             ~N[2024-02-29 13:45:01.500000],
             1.25,
             [1, 2],
             %{"a" => 1},
             170_141_183_460_469_231_731_687_303_715_884_105_727
           ]
  end

  test "errors are messages", %{db: db} do
    assert {:error, message} = Duck.query(db, "SELECT * FROM nope")
    assert message =~ "nope"
    assert {:error, _} = Duck.execute(db, "CREATE TABLE")
  end

  test "connections share the database, concurrently", %{db: db} do
    :ok = Duck.execute(db, "CREATE TABLE t AS SELECT * FROM range(1000) r(i)")

    counts =
      1..8
      |> Task.async_stream(fn _ -> Duck.query(db, "SELECT count(*) FROM t") end)
      |> Enum.map(fn {:ok, {:ok, %{rows: [[n]]}}} -> n end)

    assert counts == List.duplicate(1000, 8)
  end

  test "Table.new builds a table from columns, in order", %{db: db} do
    t =
      Table.new(db, "people",
        id: [1, 2, 3],
        name: ["a", nil, "c"],
        score: [1.5, 2.0, nil],
        ok: [true, false, true],
        born: [~D[2000-01-01], nil, ~D[1999-12-31]]
      )

    assert Table.columns(t) == ~w(id name score ok born)
    assert Table.dtypes(t)["id"] == "BIGINT"
    assert Table.dtypes(t)["born"] == "DATE"
    assert Table.count(t) == 3
    assert Table.to_columns(t)["name"] == ["a", nil, "c"]

    assert Table.rows(t, 2) == [
             %{"id" => 1, "name" => "a", "score" => 1.5, "ok" => true, "born" => ~D[2000-01-01]},
             %{"id" => 2, "name" => nil, "score" => 2.0, "ok" => false, "born" => nil}
           ]
  end

  test "Table.sql keeps a query's result as a table", %{db: db} do
    src = Table.new(db, "src", n: [3, 1, 2])
    t = Table.sql(db, "sorted", "SELECT * FROM #{Table.ref(src)} ORDER BY n")
    assert Table.to_columns(t) == %{"n" => [1, 2, 3]}
    assert t.name == "sorted"
  end

  test "an empty table keeps its columns and types", %{db: db} do
    t = Table.sql(db, "e", "SELECT 1::INTEGER AS a, 'x' AS b WHERE false")
    assert Table.columns(t) == ["a", "b"]
    assert Table.count(t) == 0
    assert Table.to_columns(t) == %{"a" => [], "b" => []}
  end

  test "SQL failures raise with DuckDB's message", %{db: db} do
    assert_raise RuntimeError, ~r/nope/, fn -> Table.sql(db, "x", "SELECT * FROM nope") end
  end
end
