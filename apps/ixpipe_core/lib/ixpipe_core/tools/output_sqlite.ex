defmodule IxpipeCore.Tools.OutputSqlite do
  @moduledoc """
  Writes its input to a table in a SQLite database (a saved `connection` or
  a database file `path`), replacing the table or appending to it, and
  passes the input through. Booleans are stored as 0 and 1.
  """
  @behaviour IxpipeCore.Tool

  alias Explorer.DataFrame
  alias Exqlite.Sqlite3
  alias IxpipeCore.Database
  alias IxpipeCore.Tools.InputSqlite

  @impl true
  def inputs, do: ["in"]

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
        save: true,
        optional: true,
        hint: "Where to write the database"
      },
      %{key: "table", label: "Table", type: :string},
      %{
        key: "mode",
        label: "If the table exists",
        type: :choice,
        options: ["replace", "append"],
        optional: true,
        default: "replace"
      }
    ]

  @impl true
  def run(%{"in" => df}, %{"table" => table} = config) do
    {:ok, conn} = Sqlite3.open(InputSqlite.path!(config))
    name = Database.quote_name(table)

    try do
      exec!(conn, "BEGIN")

      if (config["mode"] || "replace") == "replace",
        do: exec!(conn, "DROP TABLE IF EXISTS #{name}")

      # In the frame's column order, which the inserts follow; dtypes/1 is a map.
      dtypes = DataFrame.dtypes(df)

      columns =
        Enum.map_join(DataFrame.names(df), ", ", fn col ->
          "#{Database.quote_name(col)} #{sql_type(dtypes[col])}"
        end)

      exec!(conn, "CREATE TABLE IF NOT EXISTS #{name} (#{columns})")
      insert!(conn, name, df)
      exec!(conn, "COMMIT")
    rescue
      e ->
        Sqlite3.execute(conn, "ROLLBACK")
        reraise e, __STACKTRACE__
    after
      Sqlite3.close(conn)
    end

    df
  end

  defp insert!(conn, name, df) do
    names = DataFrame.names(df)
    marks = Enum.map_join(names, ", ", fn _ -> "?" end)
    {:ok, statement} = Sqlite3.prepare(conn, "INSERT INTO #{name} VALUES (#{marks})")
    columns = DataFrame.to_columns(df)

    for row <- Enum.zip(Enum.map(names, &columns[&1])) do
      :ok = Sqlite3.bind(statement, row |> Tuple.to_list() |> Enum.map(&param/1))
      :done = Sqlite3.step(conn, statement)
      :ok = Sqlite3.reset(statement)
    end

    Sqlite3.release(conn, statement)
  end

  defp param(true), do: 1
  defp param(false), do: 0
  defp param(%Date{} = d), do: Date.to_iso8601(d)
  defp param(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp param(other), do: other

  defp sql_type({kind, _}) when kind in [:s, :u], do: "INTEGER"
  defp sql_type({:f, _}), do: "REAL"
  defp sql_type(:boolean), do: "INTEGER"
  defp sql_type(_), do: "TEXT"

  defp exec!(conn, sql) do
    case Sqlite3.execute(conn, sql) do
      :ok -> :ok
      {:error, reason} -> raise "SQLite: #{reason}"
    end
  end
end
