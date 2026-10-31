defmodule IxpipeCore.Server do
  @moduledoc """
  Database servers through their pure-Elixir drivers: PostgreSQL
  (`postgrex`), MySQL and MariaDB (`myxql`) and SQL Server (`tds`). The
  database tools read a query's result into the node's table (`read/3`) and
  write a table to the server (`write/3`), replacing or appending to it.

  Writing maps DuckDB's types to the server's (`column_type/2`). Postgres
  loads rows with `COPY … FROM STDIN` from a CSV DuckDB writes; MySQL and
  SQL Server take batched multi-row `INSERT`s, in one transaction.
  """

  alias IxpipeCore.{Connections, Context, Database, Duck, Table}

  @kinds ~w(postgres mysql sqlserver)
  @names %{"postgres" => "Postgres", "mysql" => "MySQL", "sqlserver" => "SQL Server"}
  @ports %{"postgres" => 5432, "mysql" => 3306, "sqlserver" => 1433}

  @doc "The server kinds, as connection types."
  def kinds, do: @kinds

  @doc "A server kind as people write it: `\"SQL Server\"`."
  def name(kind), do: Map.fetch!(@names, kind)

  @doc "The settings of a tool that reads from a server of `kind`."
  def input_fields(kind),
    do: [
      connection_field(kind),
      %{
        key: "query",
        label: "Query",
        type: :expr,
        optional: true,
        hint: "SQL, e.g. SELECT * FROM orders"
      },
      %{
        key: "table",
        label: "Table",
        type: :string,
        optional: true,
        hint: "Or read a whole table"
      }
    ]

  @doc "The settings of a tool that writes to a server of `kind`."
  def output_fields(kind),
    do: [
      connection_field(kind),
      %{key: "table", label: "Table", type: :string, hint: "A table name, or schema.table"},
      %{
        key: "mode",
        label: "If the table exists",
        type: :choice,
        options: ["replace", "append"],
        optional: true,
        default: "replace"
      }
    ]

  defp connection_field(kind),
    do: %{
      key: "connection",
      label: "Connection",
      type: :string,
      kinds: [kind],
      hint: "A saved #{name(kind)} connection"
    }

  @doc "Runs the query `config` names on the server and keeps its result as the node's table."
  def read(kind, config, ctx) do
    conn = connection!(kind, config)

    sql =
      case config do
        %{"query" => query} when is_binary(query) and query != "" ->
          query

        %{"table" => table} when is_binary(table) and table != "" ->
          "SELECT * FROM #{target!(kind, table)}"

        _ ->
          raise "Write a query or name a table"
      end

    {columns, rows} = with_server(kind, conn, &query!(kind, &1, sql))
    Database.table(ctx, columns, rows, uuids: kind)
  end

  @doc """
  Writes `table` to the server table `config` names, saying how many rows
  went where, and passes it through.
  """
  def write(kind, %Table{} = table, config, ctx) do
    conn = connection!(kind, config)
    target = target!(kind, config["table"])
    replace = (config["mode"] || "replace") == "replace"
    dtypes = Table.dtypes(table)
    names = Table.columns(table)

    columns =
      Enum.map_join(names, ", ", &"#{quote_name(kind, &1)} #{column_type(kind, dtypes[&1])}")

    create =
      if replace,
        do: [drop(kind, target), "CREATE TABLE #{target} (#{columns})"],
        else: [create_if_missing(kind, target, columns)]

    # Postgres and SQL Server replace the table in the same transaction as
    # the load; MySQL commits on DDL, so it makes the table first.
    with_server(kind, conn, fn pid ->
      if kind == "mysql", do: Enum.each(create, &query!(kind, pid, &1))

      transaction!(kind, pid, fn pid ->
        if kind != "mysql", do: Enum.each(create, &query!(kind, pid, &1))
        load!(kind, pid, target, table, names, dtypes)
      end)
    end)

    Context.info(
      ctx,
      "Wrote #{IxpipeCore.plural(Table.count(table), "row")} to table #{config["table"]} in #{conn["name"]}."
    )

    table
  end

  defp connection!(kind, config),
    do:
      Database.connection!(config, kind) ||
        raise("Choose a saved #{name(kind)} connection")

  defp target!(_kind, table) when table in [nil, ""], do: raise("Name the table to write")

  defp target!(kind, table),
    do: table |> String.split(".") |> Enum.map_join(".", &quote_name(kind, &1))

  @doc "`name` quoted as an identifier for `kind`."
  def quote_name("postgres", name), do: Database.quote_name(name)
  def quote_name("mysql", name), do: "`" <> String.replace(name, "`", "``") <> "`"
  def quote_name("sqlserver", name), do: "[" <> String.replace(name, "]", "]]") <> "]"

  defp drop("sqlserver", target), do: "DROP TABLE IF EXISTS #{target}"
  defp drop(_kind, target), do: "DROP TABLE IF EXISTS #{target}"

  defp create_if_missing("sqlserver", target, columns),
    do:
      "IF OBJECT_ID(N'#{String.replace(target, "'", "''")}', N'U') IS NULL " <>
        "CREATE TABLE #{target} (#{columns})"

  defp create_if_missing(_kind, target, columns),
    do: "CREATE TABLE IF NOT EXISTS #{target} (#{columns})"

  @doc "The server column type for a DuckDB type."
  def column_type(kind, "DECIMAL" <> _ = decimal),
    do: if(kind == "mysql" or kind == "sqlserver", do: decimal, else: String.downcase(decimal))

  def column_type(kind, type), do: Map.get(types(kind), type) || types(kind)[:text]

  defp types("postgres"),
    do: %{
      "BOOLEAN" => "boolean",
      "TINYINT" => "smallint",
      "UTINYINT" => "smallint",
      "SMALLINT" => "smallint",
      "USMALLINT" => "integer",
      "INTEGER" => "integer",
      "UINTEGER" => "bigint",
      "BIGINT" => "bigint",
      "UBIGINT" => "numeric(20, 0)",
      "HUGEINT" => "numeric(39, 0)",
      "UHUGEINT" => "numeric(39, 0)",
      "FLOAT" => "real",
      "DOUBLE" => "double precision",
      "DATE" => "date",
      "TIMESTAMP" => "timestamp",
      "TIMESTAMP WITH TIME ZONE" => "timestamptz",
      "TIME" => "time",
      "INTERVAL" => "interval",
      "UUID" => "uuid",
      "BLOB" => "bytea",
      "JSON" => "jsonb",
      :json => "jsonb",
      :text => "text"
    }

  defp types("mysql"),
    do: %{
      "BOOLEAN" => "BOOLEAN",
      "TINYINT" => "TINYINT",
      "UTINYINT" => "TINYINT UNSIGNED",
      "SMALLINT" => "SMALLINT",
      "USMALLINT" => "SMALLINT UNSIGNED",
      "INTEGER" => "INT",
      "UINTEGER" => "INT UNSIGNED",
      "BIGINT" => "BIGINT",
      "UBIGINT" => "BIGINT UNSIGNED",
      "HUGEINT" => "DECIMAL(39, 0)",
      "UHUGEINT" => "DECIMAL(39, 0)",
      "FLOAT" => "FLOAT",
      "DOUBLE" => "DOUBLE",
      "DATE" => "DATE",
      "TIMESTAMP" => "DATETIME(6)",
      "TIMESTAMP WITH TIME ZONE" => "DATETIME(6)",
      "TIME" => "TIME(6)",
      "UUID" => "CHAR(36)",
      "BLOB" => "LONGBLOB",
      "JSON" => "JSON",
      :json => "JSON",
      :text => "LONGTEXT"
    }

  defp types("sqlserver"),
    do: %{
      "BOOLEAN" => "BIT",
      "TINYINT" => "SMALLINT",
      "UTINYINT" => "TINYINT",
      "SMALLINT" => "SMALLINT",
      "USMALLINT" => "INT",
      "INTEGER" => "INT",
      "UINTEGER" => "BIGINT",
      "BIGINT" => "BIGINT",
      "UBIGINT" => "DECIMAL(20, 0)",
      "HUGEINT" => "DECIMAL(38, 0)",
      "UHUGEINT" => "DECIMAL(38, 0)",
      "FLOAT" => "REAL",
      "DOUBLE" => "FLOAT",
      "DATE" => "DATE",
      "TIMESTAMP" => "DATETIME2",
      "TIMESTAMP WITH TIME ZONE" => "DATETIME2",
      "TIME" => "TIME",
      "UUID" => "UNIQUEIDENTIFIER",
      "BLOB" => "VARBINARY(MAX)",
      :json => "NVARCHAR(MAX)",
      :text => "NVARCHAR(MAX)"
    }

  # Lists, structs and maps go to the server as JSON.
  defp nested?(type), do: String.ends_with?(type, "]") or type =~ ~r/^(STRUCT|MAP|UNION)\(/

  # The DuckDB expression whose value the server receives for a column:
  # nested values as JSON text; for MySQL and SQL Server, exact numbers and
  # anything without an Elixir value as text.
  defp outgoing(kind, name, type) do
    col = Duck.ident(name)

    cond do
      nested?(type) -> "CAST(to_json(#{col}) AS VARCHAR)"
      kind == "postgres" and type == "BLOB" -> "'\\x' || hex(#{col})"
      kind == "postgres" -> col
      type == "TIMESTAMP WITH TIME ZONE" -> "CAST(#{col} AS TIMESTAMP)"
      type in ~w(BLOB BOOLEAN DATE TIMESTAMP TIME FLOAT DOUBLE) -> col
      type in ~w(TINYINT SMALLINT INTEGER BIGINT UTINYINT USMALLINT UINTEGER) -> col
      true -> "CAST(#{col} AS VARCHAR)"
    end
  end

  defp server_type(kind, type), do: if(nested?(type), do: types(kind)[:json], else: type)

  defp select(kind, table, names, dtypes) do
    "SELECT " <>
      Enum.map_join(names, ", ", &outgoing(kind, &1, dtypes[&1])) <>
      " FROM " <> Table.ref(table)
  end

  # Postgres: DuckDB writes the rows as CSV (empty strings quoted, NULLs
  # bare) and the server copies them in.
  defp load!("postgres", pid, target, table, names, dtypes) do
    path =
      Path.join(System.tmp_dir!(), "ixpipe-copy-#{System.unique_integer([:positive])}.csv")

    try do
      Table.exec!(
        table.db,
        "COPY (#{select("postgres", table, names, dtypes)}) TO #{Duck.literal(path)} (FORMAT csv, HEADER false)"
      )

      columns = Enum.map_join(names, ", ", &quote_name("postgres", &1))
      copy = Postgrex.stream(pid, "COPY #{target} (#{columns}) FROM STDIN (FORMAT csv)", [])
      Enum.into(File.stream!(path, 65_536), copy)
    after
      File.rm(path)
    end
  end

  # MySQL and SQL Server: multi-row INSERTs, as many rows per statement as
  # the server's parameter limit allows.
  defp load!(kind, pid, target, table, names, dtypes) do
    %{rows: rows} = Table.query!(table.db, select(kind, table, names, dtypes))
    types = Enum.map(names, &server_type(kind, dtypes[&1]))
    width = length(names)
    {max_params, max_rows} = if kind == "sqlserver", do: {2000, 1000}, else: {60_000, 5000}
    batch = max(1, min(max_rows, div(max_params, width)))
    columns = Enum.map_join(names, ", ", &quote_name(kind, &1))

    rows
    |> Enum.chunk_every(batch)
    |> Enum.each(fn chunk ->
      {values, params} = placeholders(kind, chunk, width, types)
      query!(kind, pid, "INSERT INTO #{target} (#{columns}) VALUES #{values}", params)
    end)
  end

  defp placeholders("mysql", chunk, width, _types) do
    row = "(" <> Enum.map_join(1..width, ", ", fn _ -> "?" end) <> ")"
    {Enum.map_join(chunk, ", ", fn _ -> row end), Enum.concat(chunk)}
  end

  defp placeholders("sqlserver", chunk, width, types) do
    values =
      chunk
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {_, r} ->
        "(" <> Enum.map_join(1..width, ", ", &"@#{r * width + &1}") <> ")"
      end)

    params =
      chunk
      |> Enum.concat()
      |> Enum.zip(Stream.cycle(types))
      |> Enum.with_index(1)
      |> Enum.map(fn {{value, type}, i} -> tds_param("@#{i}", value, type) end)

    {values, params}
  end

  # SQL Server checks a parameter's type even when it is NULL, and binary
  # converts implicitly to few types: NULLs go as text, blobs as binary.
  defp tds_param(name, nil, "BLOB"), do: %Tds.Parameter{name: name, value: nil, type: :binary}
  defp tds_param(name, nil, _type), do: %Tds.Parameter{name: name, value: nil, type: :string}
  defp tds_param(name, value, "BLOB"), do: %Tds.Parameter{name: name, value: value, type: :binary}

  # Tds can't encode a boolean parameter; BIT takes 1 and 0.
  defp tds_param(name, value, type) when is_boolean(value),
    do: tds_param(name, if(value, do: 1, else: 0), type)

  defp tds_param(name, value, _type) when is_integer(value),
    do: %Tds.Parameter{name: name, value: value, type: :integer}

  defp tds_param(name, value, _type), do: %Tds.Parameter{name: name, value: value}

  # -- Drivers --------------------------------------------------------------

  defp with_server(kind, conn, fun) do
    password =
      case Connections.password(conn) do
        {:ok, password} -> password
        {:error, message} -> raise message
      end

    opts =
      [
        hostname: conn["host"],
        port: port(conn["port"]) || @ports[kind],
        database: conn["database"],
        username: conn["username"],
        password: password,
        backoff_type: :stop,
        max_restarts: 0,
        pool_size: 1,
        show_sensitive_data_on_connection_error: false
      ] ++ extra(kind, conn)

    # A server that refuses the connection stops the driver's process;
    # trapping exits turns that into the query's error, not a crash.
    trap = Process.flag(:trap_exit, true)

    try do
      {:ok, pid} = driver(kind).start_link(opts)

      try do
        fun.(pid)
      catch
        # The driver's process stopped: it couldn't connect or log in.
        :exit, _ ->
          raise "#{name(kind)}: couldn't connect to #{opts[:hostname]}:#{opts[:port]}. " <>
                  "Check the connection's host, port and credentials, and that the server is running"
      after
        stop(pid)
      end
    after
      Process.flag(:trap_exit, trap)
    end
  end

  # The driver stops itself when it can't connect.
  defp stop(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp port(port) when is_integer(port), do: port

  defp port(port) when is_binary(port) do
    case Integer.parse(port) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp port(_), do: nil

  defp extra("sqlserver", conn),
    do: [ssl: conn["ssl"] == true, use_elixir_calendar_types: true]

  defp extra(_kind, _conn), do: []

  defp driver("postgres"), do: Postgrex
  defp driver("mysql"), do: MyXQL
  defp driver("sqlserver"), do: Tds

  defp transaction!(kind, pid, fun) do
    case driver(kind).transaction(pid, fn conn -> fun.(conn) end, timeout: :infinity) do
      {:ok, result} -> result
      {:error, reason} -> raise "#{name(kind)}: #{inspect(reason)}"
    end
  end

  defp query!(kind, pid, sql, params \\ []) do
    case driver(kind).query(pid, sql, params, timeout: :infinity) do
      {:ok, %{columns: columns, rows: rows}} ->
        {columns || [], rows || []}

      {:error, %{__exception__: true} = error} ->
        raise "#{name(kind)}: #{message(error)}"

      {:error, error} ->
        raise "#{name(kind)}: #{inspect(error)}"
    end
  end

  defp message(%DBConnection.ConnectionError{} = error),
    do:
      Exception.message(error) <>
        ". Check the connection's host, port and credentials, and that the server is running"

  defp message(error), do: Exception.message(error)
end
