defmodule IxpipeCore.Database do
  @moduledoc false
  # What the database tools share: finding the connection a tool's config
  # names, choosing the SQL to run, and turning result rows into a table.

  alias IxpipeCore.{Connections, Context}

  @doc "The saved connection `config` names, from its `_home` or the workflows home."
  def connection!(%{"connection" => name} = config, type) when is_binary(name) and name != "" do
    case Connections.get(config["_home"] || Connections.dir(), name) do
      {:ok, %{"type" => ^type} = conn} -> conn
      {:ok, conn} -> raise "Connection #{name} is #{conn["type"]}, not #{type}"
      {:error, message} -> raise message
    end
  end

  def connection!(_config, _type), do: nil

  @doc "The query to run: `query`, else every row of `table`."
  def sql!(%{"query" => query}) when is_binary(query) and query != "", do: query

  def sql!(%{"table" => table}) when is_binary(table) and table != "",
    do: "SELECT * FROM #{quote_name(table)}"

  def sql!(_config), do: raise("Write a query or name a table")

  def quote_name(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  @doc """
  The node's table from column names and row lists, values converted for
  DuckDB. With `uuids: "postgres"` or `"sqlserver"`, 16-byte binaries are
  UUIDs (in that server's byte order) shown as text. SQLite types values, not columns, so a column of integers and reals
  becomes DOUBLE and any other mix VARCHAR.
  """
  def table(ctx, columns, rows, opts \\ [])

  def table(%Context{}, [], _rows, _opts),
    do: raise("The query returned no columns. Write a query that selects some.")

  def table(%Context{} = ctx, columns, rows, opts) do
    uuids = Keyword.get(opts, :uuids, false)

    values =
      case rows do
        [] -> Enum.map(columns, fn _ -> [] end)
        rows -> Enum.zip_with(rows, &Enum.map(&1, fn v -> value(v, uuids) end))
      end

    Context.table(ctx, Enum.zip(columns, Enum.map(values, &unify/1)))
  end

  defp unify(values) do
    present = Enum.reject(values, &is_nil/1)

    cond do
      Enum.all?(present, &is_integer/1) -> values
      Enum.all?(present, &is_number/1) -> Enum.map(values, &(&1 && &1 * 1.0))
      present |> Enum.map(&kind/1) |> Enum.uniq() |> length() == 1 -> values
      true -> Enum.map(values, &(&1 && to_string(&1)))
    end
  end

  defp kind(%module{}), do: module
  defp kind(v) when is_binary(v), do: :string
  defp kind(v) when is_boolean(v), do: :boolean
  defp kind(_), do: :other

  defp value(%Decimal{} = d, _uuids), do: Decimal.to_float(d)

  defp value(%DateTime{} = dt, _uuids),
    do: dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive()

  defp value(%NaiveDateTime{} = dt, _uuids), do: dt
  defp value(%Date{} = d, _uuids), do: d
  defp value(%Time{} = t, _uuids), do: Time.to_string(t)
  # Text that happens to be 16 bytes long stays text.
  defp value(<<_::128>> = bin, kind) when kind in ["postgres", "sqlserver"] do
    cond do
      String.printable?(bin) -> bin
      kind == "postgres" -> uuid(bin)
      true -> sqlserver_uuid(bin)
    end
  end

  defp value(map, _uuids) when is_map(map) or is_list(map), do: Jason.encode!(map)
  defp value(other, _uuids), do: other

  # SQL Server sends a uniqueidentifier's first three groups little-endian.
  defp sqlserver_uuid(<<a::32-little, b::16-little, c::16-little, rest::binary>>),
    do: uuid(<<a::32, b::16, c::16, rest::binary>>)

  defp uuid(<<a::32, b::16, c::16, d::16, e::48>>) do
    [{a, 8}, {b, 4}, {c, 4}, {d, 4}, {e, 12}]
    |> Enum.map(fn {n, size} -> n |> Integer.to_string(16) |> String.pad_leading(size, "0") end)
    |> Enum.join("-")
    |> String.downcase()
  end
end
