defmodule IxpipeCore.Tools.InputSqlite do
  @moduledoc """
  Reads from a SQLite database: a saved `connection` or a database file
  `path`, then a `query`, or every row of a `table`. Columns keep SQLite's
  storage types (integers, reals, text; NULL stays nil).
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Database, Sqlite}

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

    case Sqlite.query(path!(config), sql) do
      {:ok, {columns, rows}} -> Database.frame(columns, rows)
      {:error, reason} -> raise "SQLite: #{reason}"
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
end
