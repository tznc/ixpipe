defmodule IxpipeCore.Table do
  @moduledoc """
  A table in a run's DuckDB database: what a tool reads and returns, and
  what Runic passes between steps. Read it with `columns/1`, `count/1`,
  `rows/2` and `to_columns/1`; make one with `new/3` (from Elixir values)
  or `sql/3` (from a query).
  """
  alias IxpipeCore.Duck
  import Duck, only: [ident: 1, literal: 1]

  @enforce_keys [:db, :name]
  defstruct [:db, :name]

  @type t :: %__MODULE__{db: Duck.db(), name: String.t()}

  @doc "The table's name, quoted for SQL."
  @spec ref(t()) :: String.t()
  def ref(%__MODULE__{name: name}), do: ident(name)

  @doc "Keeps the result of `select` as the table `name`, replacing any table of that name."
  @spec sql(Duck.db(), String.t(), String.t()) :: t()
  def sql(db, name, select) do
    exec!(db, "CREATE OR REPLACE TABLE #{ident(name)} AS #{select}")
    %__MODULE__{db: db, name: name}
  end

  @doc """
  A table `name` from `columns`, a keyword list or list of `{name, values}`
  in column order. Types follow the values: integers BIGINT, floats DOUBLE,
  booleans BOOLEAN, dates DATE, naive datetimes TIMESTAMP, anything else
  VARCHAR. A column of only nils is VARCHAR.
  """
  @spec new(Duck.db(), String.t(), [{atom() | String.t(), [term()]}]) :: t()
  def new(db, name, columns) do
    columns = Enum.map(columns, fn {k, v} -> {to_string(k), v} end)
    defs = Enum.map_join(columns, ", ", fn {k, v} -> "#{ident(k)} #{type(v)}" end)
    exec!(db, "CREATE OR REPLACE TABLE #{ident(name)} (#{defs})")

    rows = columns |> Enum.map(&elem(&1, 1)) |> Enum.zip_with(& &1)

    case Duck.append(db, name, rows) do
      :ok -> %__MODULE__{db: db, name: name}
      {:error, message} -> raise message
    end
  end

  @doc "A table `name` with `columns` (names) and `rows` (lists in column order), typed by `new/3`'s rules."
  @spec from_rows(Duck.db(), String.t(), [String.t()], [[term()]]) :: t()
  def from_rows(db, name, columns, rows) do
    values = if rows == [], do: Enum.map(columns, fn _ -> [] end), else: Enum.zip_with(rows, & &1)
    new(db, name, Enum.zip(columns, values))
  end

  @doc "Column names, in order."
  @spec columns(t()) :: [String.t()]
  def columns(table), do: Enum.map(describe(table), &elem(&1, 0))

  @doc "DuckDB types by column name (`\"BIGINT\"`, `\"VARCHAR\"`, …)."
  @spec dtypes(t()) :: %{String.t() => String.t()}
  def dtypes(table), do: Map.new(describe(table))

  @doc "The number of rows."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{db: db} = table) do
    %{rows: [[n]]} = query!(db, "SELECT count(*) FROM #{ref(table)}")
    n
  end

  @doc "Rows as maps of column to value, in table order; at most `limit`."
  @spec rows(t(), non_neg_integer() | nil) :: [%{String.t() => term()}]
  def rows(table, limit \\ nil) do
    %{columns: columns, rows: rows} = select(table, limit)
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end

  @doc "`{columns, rows}`, rows as lists in column order; at most `limit`."
  @spec values(t(), non_neg_integer() | nil) :: {[String.t()], [[term()]]}
  def values(table, limit \\ nil) do
    %{columns: columns, rows: rows} = select(table, limit)
    {columns, rows}
  end

  @doc "Every column's values, by column name."
  @spec to_columns(t()) :: %{String.t() => [term()]}
  def to_columns(table) do
    {columns, rows} = values(table)

    case rows do
      [] -> Map.new(columns, &{&1, []})
      rows -> columns |> Enum.zip(Enum.zip_with(rows, & &1)) |> Map.new()
    end
  end

  defp select(%__MODULE__{db: db} = table, limit) do
    query!(db, "SELECT * FROM #{ref(table)}" <> if(limit, do: " LIMIT #{limit}", else: ""))
  end

  defp describe(%__MODULE__{db: db, name: name}) do
    %{rows: rows} =
      query!(db, """
      SELECT column_name, data_type FROM information_schema.columns
      WHERE table_name = #{literal(name)} ORDER BY ordinal_position
      """)

    Enum.map(rows, &List.to_tuple/1)
  end

  defp type(values) do
    case Enum.find(values, &(&1 != nil)) do
      v when is_integer(v) -> "BIGINT"
      v when is_float(v) -> "DOUBLE"
      v when is_boolean(v) -> "BOOLEAN"
      %Date{} -> "DATE"
      %NaiveDateTime{} -> "TIMESTAMP"
      %DateTime{} -> "TIMESTAMP"
      %Time{} -> "TIME"
      %Decimal{} -> "DOUBLE"
      _ -> "VARCHAR"
    end
  end

  @doc false
  def exec!(db, sql) do
    case Duck.execute(db, sql) do
      :ok -> :ok
      {:error, message} -> raise message
    end
  end

  @doc false
  def query!(db, sql) do
    case Duck.query(db, sql) do
      {:ok, result} -> result
      {:error, message} -> raise message
    end
  end
end

defimpl Runic.Identity.Projectable, for: IxpipeCore.Table do
  # Runic hashes every fact it produces: a table is its name within its run.
  def identity_document(%{name: name}), do: %{table: name}
end
