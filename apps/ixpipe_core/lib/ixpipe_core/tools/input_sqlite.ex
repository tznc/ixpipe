defmodule IxpipeCore.Tools.InputSqlite do
  @moduledoc """
  Reads from a SQLite database: a saved `connection` or a database file
  `path`, then a `query`, or every row of a `table`. Columns keep SQLite's
  storage types (integers, reals, text; NULL stays nil).
  """
  @behaviour IxpipeCore.Tool

  alias Exqlite.Sqlite3
  alias IxpipeCore.Database

  @impl true
  def inputs, do: []

  @impl true
  def fields,
    do: [
      %{
        key: "connection",
        label: "Connection",
        type: :string,
        optional: true,
        hint: "A saved SQLite connection, or choose a file below"
      },
      %{
        key: "path",
        label: "File",
        type: :path,
        accept: ["sqlite", "db", "sqlite3"],
        optional: true,
        hint: "A SQLite database on this computer"
      },
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

  @impl true
  def run(_inputs, config) do
    sql = Database.sql!(config)
    {:ok, conn} = Sqlite3.open(path!(config), mode: :readonly)

    try do
      {columns, rows} = query!(conn, sql)
      Database.frame(columns, rows)
    after
      Sqlite3.close(conn)
    end
  end

  @doc false
  def path!(config) do
    case {Database.connection!(config, "sqlite"), config["path"]} do
      {%{"path" => path}, _} -> path
      {nil, path} when is_binary(path) and path != "" -> path
      {nil, _} -> raise "Choose a saved connection or a database file"
    end
  end

  defp query!(conn, sql) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql),
         {:ok, columns} <- Sqlite3.columns(conn, statement),
         {:ok, rows} <- Sqlite3.fetch_all(conn, statement) do
      Sqlite3.release(conn, statement)
      {columns, rows}
    else
      {:error, reason} -> raise "SQLite: #{reason}"
    end
  end
end
