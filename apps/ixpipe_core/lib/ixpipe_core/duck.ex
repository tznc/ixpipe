defmodule IxpipeCore.Duck do
  @moduledoc """
  DuckDB v2, ixpipe's engine, through a Rust NIF (`native/ixpipe_duckdb`)
  with DuckDB bundled, so every target (Android included) builds the same
  engine. A run opens one in-memory database; every call gets its own
  connection to it, so Runic steps on different branches run concurrently.
  Past `memory_limit`, DuckDB spills to `temp_directory`.
  """
  use Rustler, otp_app: :ixpipe_core, crate: "ixpipe_duckdb", mode: :release

  @type db :: reference()
  @type result :: %{columns: [String.t()], rows: [[term()]]}

  @epoch ~D[1970-01-01]
  @epoch_time ~N[1970-01-01 00:00:00]

  @doc "Opens an in-memory database. `settings` are `SET` options."
  @spec open([{String.t(), String.t()}]) :: {:ok, db()} | {:error, String.t()}
  def open(settings \\ []) do
    temp = Path.join(System.tmp_dir!(), "ixpipe-duckdb")
    open_nif([{"temp_directory", temp} | settings])
  end

  @doc "Runs one or more statements."
  @spec execute(db(), String.t()) :: :ok | {:error, String.t()}
  def execute(db, sql) do
    case execute_nif(db, sql) do
      {:ok, {}} -> :ok
      other -> other
    end
  end

  @doc "Runs a query. Dates, times and timestamps come back as Elixir structs."
  @spec query(db(), String.t()) :: {:ok, result()} | {:error, String.t()}
  def query(db, sql) do
    with {:ok, {columns, rows}} <- query_nif(db, sql),
         do: {:ok, %{columns: columns, rows: Enum.map(rows, &Enum.map(&1, fn v -> value(v) end))}}
  end

  @doc "Appends `rows` (lists in column order) to the table `name`."
  @spec append(db(), String.t(), [[term()]]) :: :ok | {:error, String.t()}
  def append(db, name, rows) do
    case append_nif(db, name, Enum.map(rows, &Enum.map(&1, fn v -> param(v) end))) do
      {:ok, {}} -> :ok
      other -> other
    end
  end

  @doc "Quotes `name` as an SQL identifier."
  @spec ident(String.t()) :: String.t()
  def ident(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  @doc "Quotes `text` as an SQL string."
  @spec literal(String.t()) :: String.t()
  def literal(text), do: "'" <> String.replace(text, "'", "''") <> "'"

  defp value({:date, days}), do: Date.add(@epoch, days)
  defp value({:timestamp, us}), do: NaiveDateTime.add(@epoch_time, us, :microsecond)
  defp value({:time, us}), do: Time.add(~T[00:00:00.000000], us, :microsecond)
  defp value({:int, digits}), do: String.to_integer(digits)

  defp value({:interval, months, days, nanos}),
    do: %Duration{month: months, day: days, microsecond: {div(nanos, 1000), 6}}

  defp value(list) when is_list(list), do: Enum.map(list, &value/1)
  defp value(map) when is_map(map), do: Map.new(map, fn {k, v} -> {value(k), value(v)} end)
  defp value(other), do: other

  defp param(%Date{} = d), do: {:date, Date.diff(d, @epoch)}

  defp param(%NaiveDateTime{} = dt),
    do: {:timestamp, NaiveDateTime.diff(dt, @epoch_time, :microsecond)}

  defp param(%DateTime{} = dt), do: param(DateTime.to_naive(dt))
  defp param(%Time{} = t), do: {:time, Time.diff(t, ~T[00:00:00], :microsecond)}
  defp param(%Decimal{} = d), do: Decimal.to_float(d)
  defp param(other), do: other

  @doc false
  def open_nif(_settings), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def execute_nif(_db, _sql), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def query_nif(_db, _sql), do: :erlang.nif_error(:nif_not_loaded)
  @doc false
  def append_nif(_db, _name, _rows), do: :erlang.nif_error(:nif_not_loaded)
end
