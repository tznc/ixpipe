defmodule IxpipeCore.SqliteNifTest do
  # The SQLite NIF: rusqlite with SQLite bundled, so every platform (Android
  # included) builds the same library from source.
  use ExUnit.Case, async: true
  alias IxpipeCore.Sqlite

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-nif-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{db: Path.join(dir, "t.db")}
  end

  test "executes statements and queries rows with SQLite's types", %{db: db} do
    assert :ok =
             Sqlite.execute(db, """
             CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB);
             INSERT INTO t VALUES (1, 1.5, 'a', x'0102'), (NULL, NULL, NULL, NULL);
             """)

    assert {:ok, {["i", "r", "s", "b"], rows}} = Sqlite.query(db, "SELECT * FROM t")
    assert rows == [[1, 1.5, "a", <<1, 2>>], [nil, nil, nil, nil]]
  end

  test "an empty result keeps its columns", %{db: db} do
    :ok = Sqlite.execute(db, "CREATE TABLE t (a INTEGER, b TEXT)")
    assert {:ok, {["a", "b"], []}} = Sqlite.query(db, "SELECT a, b FROM t")
  end

  test "writes rows in one transaction, all or nothing", %{db: db} do
    assert :ok =
             Sqlite.write(db, ["CREATE TABLE t (a INTEGER, b)"], "INSERT INTO t VALUES (?, ?)", [
               [1, "x"],
               [2, nil],
               [3, 2.5]
             ])

    assert {:ok, {_, [[1, "x"], [2, nil], [3, 2.5]]}} = Sqlite.query(db, "SELECT * FROM t")

    assert {:error, message} =
             Sqlite.write(db, ["DELETE FROM t"], "INSERT INTO nope VALUES (?)", [[1]])

    assert message =~ "no such table"
    assert {:ok, {_, [_, _, _]}} = Sqlite.query(db, "SELECT * FROM t")
  end

  test "errors are messages, and queries never create a file", %{db: db} do
    assert {:error, message} = Sqlite.query(db, "SELECT 1")
    assert is_binary(message)
    refute File.exists?(db)

    :ok = Sqlite.execute(db, "CREATE TABLE t (a)")
    assert {:error, message} = Sqlite.query(db, "SELECT * FROM missing")
    assert message =~ "no such table"
    assert {:error, _} = Sqlite.query(db, "DELETE FROM t")
  end
end
