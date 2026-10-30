defmodule IxpipeCore.Database do
  @moduledoc false
  # What the database tools share: finding the connection a tool's config
  # names, choosing the SQL to run, and turning result rows into a frame.

  alias Explorer.DataFrame
  alias IxpipeCore.Connections

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
  A frame from column names and row lists, values converted for Explorer.
  With `uuids: true` (Postgres), 16-byte binaries are UUIDs shown as text.
  """
  def frame(columns, rows, opts \\ []) do
    uuids = Keyword.get(opts, :uuids, false)

    values =
      rows
      |> Enum.map(fn row -> Enum.map(row, &value(&1, uuids)) end)
      |> transpose(length(columns))

    columns |> Enum.zip(values) |> DataFrame.new()
  end

  defp transpose(rows, width) do
    case rows do
      [] -> List.duplicate([], width)
      rows -> rows |> Enum.zip() |> Enum.map(&Tuple.to_list/1)
    end
  end

  defp value(%Decimal{} = d, _uuids), do: Decimal.to_float(d)

  defp value(%DateTime{} = dt, _uuids),
    do: dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive()

  defp value(%NaiveDateTime{} = dt, _uuids), do: dt
  defp value(%Date{} = d, _uuids), do: d
  defp value(%Time{} = t, _uuids), do: Time.to_string(t)
  defp value(<<_::128>> = bin, true), do: uuid(bin)
  defp value(map, _uuids) when is_map(map) or is_list(map), do: Jason.encode!(map)
  defp value(other, _uuids), do: other

  defp uuid(<<a::32, b::16, c::16, d::16, e::48>>) do
    [{a, 8}, {b, 4}, {c, 4}, {d, 4}, {e, 12}]
    |> Enum.map(fn {n, size} -> n |> Integer.to_string(16) |> String.pad_leading(size, "0") end)
    |> Enum.join("-")
    |> String.downcase()
  end
end
