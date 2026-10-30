defmodule IxpipeCore.SqliteTest do
  use ExUnit.Case, async: true
  alias Explorer.DataFrame, as: DF
  alias Exqlite.Sqlite3
  alias IxpipeCore.Connections
  alias IxpipeCore.Tools.{InputSqlite, OutputSqlite}

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-sqlite-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    db = Path.join(dir, "shop.db")

    {:ok, conn} = Sqlite3.open(db)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE orders (id INTEGER, amount REAL, customer TEXT, note TEXT);
      INSERT INTO orders VALUES (1, 50.5, 'Ada', NULL), (2, 5.0, 'Bob', 'rush'), (3, 30.25, 'Ada', NULL);
      """)

    :ok = Sqlite3.close(conn)
    %{dir: dir, db: db}
  end

  test "reads a table, keeping names, types and NULLs", %{db: db} do
    df = InputSqlite.run(%{}, %{"path" => db, "table" => "orders"})
    assert DF.names(df) == ["id", "amount", "customer", "note"]
    cols = DF.to_columns(df)
    assert cols["id"] == [1, 2, 3]
    assert cols["amount"] == [50.5, 5.0, 30.25]
    assert cols["customer"] == ["Ada", "Bob", "Ada"]
    assert cols["note"] == [nil, "rush", nil]
    assert DF.dtypes(df)["id"] == {:s, 64}
  end

  test "reads a query", %{db: db} do
    df =
      InputSqlite.run(%{}, %{
        "path" => db,
        "query" =>
          "SELECT customer, SUM(amount) AS total FROM orders GROUP BY customer ORDER BY customer"
      })

    assert DF.to_columns(df) == %{"customer" => ["Ada", "Bob"], "total" => [80.75, 5.0]}
  end

  test "an empty result keeps its columns", %{db: db} do
    df =
      InputSqlite.run(%{}, %{
        "path" => db,
        "query" => "SELECT id, customer FROM orders WHERE id > 99"
      })

    assert DF.names(df) == ["id", "customer"]
    assert DF.n_rows(df) == 0
  end

  test "reads through a saved connection", %{dir: dir, db: db} do
    :ok = Connections.put(dir, %{"name" => "shop", "type" => "sqlite", "path" => db})
    df = InputSqlite.run(%{}, %{"connection" => "shop", "table" => "orders", "_home" => dir})
    assert DF.n_rows(df) == 3
  end

  test "says what is missing or wrong", %{dir: dir, db: db} do
    assert_raise RuntimeError, "Choose a saved connection or a database file", fn ->
      InputSqlite.run(%{}, %{"table" => "orders"})
    end

    assert_raise RuntimeError, "Write a query or name a table", fn ->
      InputSqlite.run(%{}, %{"path" => db})
    end

    assert_raise RuntimeError, "No saved connection named nope", fn ->
      InputSqlite.run(%{}, %{"connection" => "nope", "table" => "orders", "_home" => dir})
    end

    error =
      assert_raise RuntimeError, fn ->
        InputSqlite.run(%{}, %{"path" => db, "table" => "missing"})
      end

    assert error.message =~ "no such table"
  end

  test "writes a frame, replacing or appending", %{db: db} do
    df = DF.new(id: [1, 2], name: ["a", nil], score: [1.5, 2.0], ok: [true, false])
    assert ^df = OutputSqlite.run(%{"in" => df}, %{"path" => db, "table" => "scores"})
    back = InputSqlite.run(%{}, %{"path" => db, "table" => "scores"})

    assert DF.to_columns(back) == %{
             "id" => [1, 2],
             "name" => ["a", nil],
             "score" => [1.5, 2.0],
             "ok" => [1, 0]
           }

    OutputSqlite.run(%{"in" => df}, %{"path" => db, "table" => "scores", "mode" => "append"})
    assert DF.n_rows(InputSqlite.run(%{}, %{"path" => db, "table" => "scores"})) == 4

    OutputSqlite.run(%{"in" => df}, %{"path" => db, "table" => "scores"})
    assert DF.n_rows(InputSqlite.run(%{}, %{"path" => db, "table" => "scores"})) == 2
  end

  test "a workflow reads, sorts and writes SQLite", %{dir: dir, db: db} do
    :ok = Connections.put(dir, %{"name" => "shop", "type" => "sqlite", "path" => db})

    {:ok, spec} =
      IxpipeCore.Spec.parse("""
      nodes:
        - {id: orders, tool: input_sqlite, config: {path: #{db}, table: orders}}
        - {id: sorted, tool: sort, inputs: {in: orders}, config: {by: [amount], desc: true}}
        - {id: out, tool: output_sqlite, inputs: {in: sorted}, config: {connection: shop, _home: #{dir}, table: ranked}}
      """)

    assert {:ok, _} = IxpipeCore.run(spec)
    ranked = InputSqlite.run(%{}, %{"path" => db, "table" => "ranked"})
    assert DF.to_columns(ranked)["id"] == [1, 3, 2]
  end

  test "the tools are registered with their settings" do
    assert IxpipeCore.Tools.lookup("input_sqlite") == InputSqlite
    assert IxpipeCore.Tools.lookup("output_sqlite") == OutputSqlite
    assert Enum.map(InputSqlite.fields(), & &1.key) == ["connection", "path", "query", "table"]
    assert IxpipeCore.Tools.required(InputSqlite) == []
    assert IxpipeCore.Tools.required(OutputSqlite) == ["table"]
  end
end
