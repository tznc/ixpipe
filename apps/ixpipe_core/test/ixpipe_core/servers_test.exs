# Writing to and reading from database servers: Postgres (`:postgres`),
# MySQL (`:mysql`) and SQL Server (`:mssql`), each excluded by default and
# run against a local server (see AGENTS.md for the setup and the
# environment variables that point the tests elsewhere).
servers = [
  %{
    kind: "postgres",
    tag: :postgres,
    host: System.get_env("IXPIPE_PG_HOST", "localhost"),
    port: System.get_env("IXPIPE_PG_PORT", "5432"),
    database: System.get_env("IXPIPE_PG_DATABASE", "ixpipe_test"),
    username: System.get_env("IXPIPE_PG_USER", "ixpipe"),
    password_env: "PGPASSWORD",
    # Booleans read back as booleans; a timestamp keeps its microseconds.
    bool: [true, false, nil]
  },
  %{
    kind: "mysql",
    tag: :mysql,
    host: System.get_env("IXPIPE_MYSQL_HOST", "127.0.0.1"),
    port: System.get_env("IXPIPE_MYSQL_PORT", "3306"),
    database: System.get_env("IXPIPE_MYSQL_DATABASE", "ixpipe_test"),
    username: System.get_env("IXPIPE_MYSQL_USER", "ixpipe"),
    password_env: "MYSQL_PWD",
    # MySQL's BOOLEAN is TINYINT(1).
    bool: [1, 0, nil]
  },
  %{
    kind: "sqlserver",
    tag: :mssql,
    host: System.get_env("IXPIPE_MSSQL_HOST", "localhost"),
    port: System.get_env("IXPIPE_MSSQL_PORT", "1433"),
    database: System.get_env("IXPIPE_MSSQL_DATABASE", "ixpipe_test"),
    username: System.get_env("IXPIPE_MSSQL_USER", "sa"),
    password_env: "SQLCMDPASSWORD",
    bool: [true, false, nil]
  }
]

for server <- servers do
  defmodule Module.concat(IxpipeCore.ServersTest, Macro.camelize(server.kind)) do
    use ExUnit.Case, async: false
    alias IxpipeCore.{Connections, Context, Server, Table, Tools}

    @moduletag server.tag
    @server server
    @kind server.kind
    @input Tools.lookup("input_#{server.kind}")
    @output Tools.lookup("output_#{server.kind}")

    setup do
      dir = Path.join(System.tmp_dir!(), "ixpipe-#{@kind}-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      conn = %{
        "name" => "warehouse",
        "type" => @kind,
        "host" => @server.host,
        "port" => String.to_integer(@server.port),
        "database" => @server.database,
        "username" => @server.username,
        "password_env" => @server.password_env
      }

      if @kind == "sqlserver", do: create_database!(conn)
      :ok = Connections.put(dir, conn)
      ctx = Context.new()
      config = %{"connection" => "warehouse", "_home" => dir}
      sql!(ctx, config, "DROP TABLE IF EXISTS ixpipe_written")
      %{dir: dir, ctx: ctx, config: config}
    end

    # SQL Server has no CREATE DATABASE IF NOT EXISTS, and no database to
    # name until one exists: make it from master.
    defp create_database!(conn) do
      dir = Path.join(System.tmp_dir!(), "ixpipe-master-#{System.unique_integer([:positive])}")
      :ok = Connections.put(dir, %{conn | "database" => "master"})

      sql!(
        Context.new(),
        %{"connection" => "warehouse", "_home" => dir},
        "IF DB_ID('#{conn["database"]}') IS NULL CREATE DATABASE #{conn["database"]}"
      )

      File.rm_rf!(dir)
    end

    # Runs a statement on the server, through the input tool; it returns no
    # columns, which the tool reports.
    defp sql!(ctx, config, sql) do
      @input.run(%{}, Map.put(config, "query", sql), ctx)
    rescue
      e in RuntimeError -> if e.message =~ "no columns", do: :ok, else: reraise(e, __STACKTRACE__)
    end

    defp read(ctx, config, extra), do: @input.run(%{}, Map.merge(config, extra), ctx)

    defp source(ctx) do
      Table.sql(ctx.db, "src", """
      SELECT * FROM (VALUES
        (1, 50.5, 'Ada', true, DATE '2026-01-02', TIMESTAMP '2026-01-02 10:00:00.123456', 12.30::DECIMAL(10, 2), [1, 2]),
        (2, -1.25, '', false, DATE '1999-12-31', TIMESTAMP '1999-12-31 23:59:59', 0.05::DECIMAL(10, 2), []),
        (9000000000, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
      ) t(id, amount, "customer name", paid, placed, seen, price, tags)
      """)
    end

    test "writes a table that reads back with its types and NULLs", %{ctx: ctx, config: config} do
      src = source(ctx)
      assert @output.run(%{"in" => src}, Map.put(config, "table", "ixpipe_written"), ctx) == src

      back = read(ctx, config, %{"query" => "SELECT * FROM ixpipe_written ORDER BY id"})

      assert Table.columns(back) ==
               ["id", "amount", "customer name", "paid", "placed", "seen", "price", "tags"]

      cols = Table.to_columns(back)
      assert cols["id"] == [1, 2, 9_000_000_000]
      assert cols["amount"] == [50.5, -1.25, nil]
      # An empty string stays empty, apart from NULL.
      assert cols["customer name"] == ["Ada", "", nil]
      assert cols["paid"] == @server.bool
      assert cols["placed"] == [~D[2026-01-02], ~D[1999-12-31], nil]

      assert cols["seen"] == [
               ~N[2026-01-02 10:00:00.123456],
               ~N[1999-12-31 23:59:59.000000],
               nil
             ]

      assert cols["price"] == [12.3, 0.05, nil]
      assert Enum.map(cols["tags"], &(&1 && Jason.decode!(&1))) == [[1, 2], [], nil]
    end

    test "replaces the table by default, or appends to it", %{ctx: ctx, config: config} do
      config = Map.put(config, "table", "ixpipe_written")
      one = Table.new(ctx.db, "one", id: [1], name: ["a"])
      two = Table.new(ctx.db, "two", id: [2, 3], name: ["b", "c"])

      @output.run(%{"in" => one}, config, ctx)
      @output.run(%{"in" => two}, config, ctx)
      assert Table.count(read(ctx, config, %{"table" => "ixpipe_written"})) == 2

      @output.run(%{"in" => one}, Map.put(config, "mode", "append"), ctx)
      back = read(ctx, config, %{"query" => "SELECT id FROM ixpipe_written ORDER BY id"})
      assert Table.to_columns(back) == %{"id" => [1, 2, 3]}
    end

    test "appending creates a missing table", %{ctx: ctx, config: config} do
      config = Map.merge(config, %{"table" => "ixpipe_written", "mode" => "append"})
      @output.run(%{"in" => Table.new(ctx.db, "one", id: [1])}, config, ctx)
      assert Table.count(read(ctx, config, %{"table" => "ixpipe_written"})) == 1
    end

    test "writes more rows than one batch holds", %{ctx: ctx, config: config} do
      src =
        Table.sql(
          ctx.db,
          "many",
          "SELECT range AS id, 'row ' || range AS label FROM range(12000)"
        )

      @output.run(%{"in" => src}, Map.put(config, "table", "ixpipe_written"), ctx)

      back =
        read(ctx, config, %{
          "query" => "SELECT COUNT(*) AS n, SUM(id) AS total FROM ixpipe_written"
        })

      assert %{"n" => [12000]} = Table.to_columns(back)
      assert hd(Table.to_columns(back)["total"]) == 11999 * 12000 / 2
    end

    test "an empty result keeps its columns", %{ctx: ctx, config: config} do
      @output.run(
        %{"in" => Table.new(ctx.db, "one", id: [1], name: ["a"])},
        Map.put(config, "table", "ixpipe_written"),
        ctx
      )

      back = read(ctx, config, %{"query" => "SELECT id, name FROM ixpipe_written WHERE id > 99"})
      assert Table.columns(back) == ["id", "name"]
      assert Table.count(back) == 0
    end

    test "surfaces the server's error", %{ctx: ctx, config: config} do
      error =
        assert_raise RuntimeError, fn -> read(ctx, config, %{"table" => "missing_table"}) end

      assert error.message =~ Server.name(@kind) <> ": "
      assert error.message =~ "missing_table"
    end

    test "a server that isn't there says what to check", %{ctx: ctx, dir: dir, config: config} do
      {:ok, conn} = Connections.get(dir, "warehouse")
      :ok = Connections.put(dir, %{conn | "name" => "nowhere", "port" => 1})

      error =
        assert_raise RuntimeError, fn ->
          read(ctx, %{config | "connection" => "nowhere"}, %{"table" => "x"})
        end

      assert error.message =~ "Check the connection's host, port and credentials"
    end
  end
end

defmodule IxpipeCore.ServersTest do
  # Without a server: the tools' settings, the type mapping and the
  # mistakes a workflow can make before it reaches a server.
  use ExUnit.Case, async: true
  alias IxpipeCore.{Connections, Context, Server, Table, Tools}

  test "each server has input and output tools whose connection takes its kind" do
    for kind <- ~w(postgres mysql sqlserver), dir <- ~w(input output) do
      tool = Tools.lookup("#{dir}_#{kind}")
      assert tool, "#{dir}_#{kind}"
      assert [%{key: "connection", kinds: [^kind]} | _] = tool.fields()
    end

    assert Tools.required(Tools.OutputPostgres) == ["connection", "table"]
  end

  test "DuckDB types map to each server's" do
    assert Server.column_type("postgres", "DOUBLE") == "double precision"
    assert Server.column_type("postgres", "DECIMAL(10,2)") == "decimal(10,2)"
    assert Server.column_type("postgres", "TIMESTAMP WITH TIME ZONE") == "timestamptz"
    assert Server.column_type("postgres", "VARCHAR") == "text"
    assert Server.column_type("mysql", "VARCHAR") == "LONGTEXT"
    assert Server.column_type("mysql", "TIMESTAMP") == "DATETIME(6)"
    assert Server.column_type("sqlserver", "BOOLEAN") == "BIT"
    assert Server.column_type("sqlserver", "VARCHAR") == "NVARCHAR(MAX)"
    assert Server.column_type("sqlserver", "DOUBLE") == "FLOAT"
    # Anything unmapped (lists, structs, enums) is text.
    assert Server.column_type("sqlserver", "INTEGER[]") == "NVARCHAR(MAX)"
  end

  test "names are quoted for each server, schema and table apart" do
    assert Server.quote_name("postgres", ~s(a"b)) == ~s("a""b")
    assert Server.quote_name("mysql", "a`b") == "`a``b`"
    assert Server.quote_name("sqlserver", "a]b") == "[a]]b]"
  end

  test "a tool needs a saved connection of its kind" do
    dir = Path.join(System.tmp_dir!(), "ixpipe-kinds-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    :ok = Connections.put(dir, %{"name" => "shop", "type" => "sqlite", "path" => "/x.db"})
    ctx = Context.new()
    src = Table.new(ctx.db, "src", id: [1])

    assert_raise RuntimeError, "Choose a saved MySQL connection", fn ->
      Tools.OutputMysql.run(%{"in" => src}, %{"table" => "t"}, ctx)
    end

    assert_raise RuntimeError, "Connection shop is sqlite, not sqlserver", fn ->
      Tools.InputSqlserver.run(
        %{},
        %{"connection" => "shop", "_home" => dir, "table" => "t"},
        ctx
      )
    end
  end
end
