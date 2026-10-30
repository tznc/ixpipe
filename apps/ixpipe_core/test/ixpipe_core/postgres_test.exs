defmodule IxpipeCore.PostgresTest do
  # Needs a PostgreSQL server: see AGENTS.md (`mix test --only postgres`).
  # Connection settings come from IXPIPE_PG_HOST/PORT/DATABASE/USER and
  # PGPASSWORD (defaults: localhost, 5432, ixpipe_test, ixpipe).
  use ExUnit.Case, async: false
  alias IxpipeCore.{Connections, Context, Table}
  alias IxpipeCore.Tools.InputPostgres

  @moduletag :postgres

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-pg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    conn = %{
      "name" => "warehouse",
      "type" => "postgres",
      "host" => System.get_env("IXPIPE_PG_HOST", "localhost"),
      "port" => String.to_integer(System.get_env("IXPIPE_PG_PORT", "5432")),
      "database" => System.get_env("IXPIPE_PG_DATABASE", "ixpipe_test"),
      "username" => System.get_env("IXPIPE_PG_USER", "ixpipe"),
      "password_env" => "PGPASSWORD"
    }

    :ok = Connections.put(dir, conn)
    {:ok, password} = Connections.password(conn)

    {:ok, pid} =
      Postgrex.start_link(
        hostname: conn["host"],
        port: conn["port"],
        database: conn["database"],
        username: conn["username"],
        password: password
      )

    Postgrex.query!(pid, "DROP TABLE IF EXISTS ixpipe_orders", [])

    Postgrex.query!(
      pid,
      """
      CREATE TABLE ixpipe_orders (
        id integer, amount double precision, price numeric(10, 2), customer text,
        paid boolean, placed date, seen timestamp, seen_tz timestamptz, ref uuid, big bigint
      )
      """,
      []
    )

    Postgrex.query!(
      pid,
      """
      INSERT INTO ixpipe_orders VALUES
        (1, 50.5, 12.30, 'Ada', true, '2026-01-02', '2026-01-02 10:00:00', '2026-01-02 10:00:00+00',
         '6f0b6a3c-2a7b-4a4f-9c35-2b1f3a8d9e01', 9000000000),
        (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
      """,
      []
    )

    GenServer.stop(pid)
    %{dir: dir}
  end

  defp read(dir, config),
    do:
      InputPostgres.run(
        %{},
        Map.merge(%{"connection" => "warehouse", "_home" => dir}, config),
        Context.new()
      )

  test "reads a table with its types and NULLs", %{dir: dir} do
    df = read(dir, %{"table" => "ixpipe_orders"})

    assert Table.columns(df) ==
             ~w(id amount price customer paid placed seen seen_tz ref big)

    cols = Table.to_columns(df)
    assert cols["id"] == [1, 2]
    assert cols["amount"] == [50.5, nil]
    assert cols["price"] == [12.3, nil]
    assert cols["customer"] == ["Ada", nil]
    assert cols["paid"] == [true, nil]
    assert cols["placed"] == [~D[2026-01-02], nil]
    assert cols["seen"] == [~N[2026-01-02 10:00:00.000000], nil]
    assert cols["seen_tz"] == [~N[2026-01-02 10:00:00.000000], nil]
    assert cols["ref"] == ["6f0b6a3c-2a7b-4a4f-9c35-2b1f3a8d9e01", nil]
    assert cols["big"] == [9_000_000_000, nil]
  end

  test "reads a query", %{dir: dir} do
    df = read(dir, %{"query" => "SELECT id, customer FROM ixpipe_orders WHERE id = 1"})
    assert Table.to_columns(df) == %{"id" => [1], "customer" => ["Ada"]}
  end

  test "an empty result keeps its columns", %{dir: dir} do
    df = read(dir, %{"query" => "SELECT id, customer FROM ixpipe_orders WHERE id > 99"})
    assert Table.columns(df) == ["id", "customer"]
    assert Table.count(df) == 0
  end

  # A DuckDB table needs a column, so a statement that returns none fails.
  test "a statement without columns says so", %{dir: dir} do
    assert_raise RuntimeError,
                 "The query returned no columns. Write a query that selects some.",
                 fn ->
                   read(dir, %{"query" => "UPDATE ixpipe_orders SET id = id WHERE false"})
                 end
  end

  test "surfaces the database's error", %{dir: dir} do
    error = assert_raise RuntimeError, fn -> read(dir, %{"table" => "missing_table"}) end
    assert error.message =~ "missing_table"
  end

  test "names a missing password variable", %{dir: dir} do
    password = System.get_env("PGPASSWORD")
    System.delete_env("PGPASSWORD")
    on_exit(fn -> System.put_env("PGPASSWORD", password) end)

    assert_raise RuntimeError,
                 "Set the environment variable PGPASSWORD to the password for connection warehouse",
                 fn -> read(dir, %{"table" => "ixpipe_orders"}) end
  end
end
