defmodule IxpipeCore.Tools.OutputSqlite do
  @moduledoc """
  Writes its input to a table in a SQLite database (a saved `connection` or
  a database file `path`), replacing the table or appending to it, and
  passes the input through. Booleans are stored as 0 and 1.
  """
  @behaviour IxpipeCore.Tool

  alias Explorer.DataFrame
  alias IxpipeCore.{Database, Sqlite}
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
    name = Database.quote_name(table)
    names = DataFrame.names(df)
    # In the frame's column order, which the inserts follow; dtypes/1 is a map.
    dtypes = DataFrame.dtypes(df)

    columns =
      Enum.map_join(names, ", ", fn col ->
        "#{Database.quote_name(col)} #{sql_type(dtypes[col])}"
      end)

    drop =
      if (config["mode"] || "replace") == "replace",
        do: ["DROP TABLE IF EXISTS #{name}"],
        else: []

    marks = Enum.map_join(names, ", ", fn _ -> "?" end)
    data = DataFrame.to_columns(df)

    rows =
      names
      |> Enum.map(&data[&1])
      |> Enum.zip_with(fn row -> Enum.map(row, &param/1) end)

    case Sqlite.write(
           InputSqlite.path!(config),
           drop ++ ["CREATE TABLE IF NOT EXISTS #{name} (#{columns})"],
           "INSERT INTO #{name} VALUES (#{marks})",
           rows
         ) do
      :ok -> df
      {:error, reason} -> raise "SQLite: #{reason}"
    end
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
end
