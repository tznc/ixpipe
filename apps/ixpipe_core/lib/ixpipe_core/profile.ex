defmodule IxpipeCore.Profile do
  @moduledoc """
  A profile of a table's columns, as Alteryx's Browse shows beside the data:
  for each, its type, how many values are NULL and how many distinct, the
  range of a number or date, the most common values of anything else, and
  a ten-bin histogram of a number. All SQL on the run's table.
  """
  alias IxpipeCore.Table
  import IxpipeCore.Duck, only: [ident: 1]

  @type column :: %{
          name: String.t(),
          type: String.t(),
          count: non_neg_integer(),
          nulls: non_neg_integer(),
          distinct: non_neg_integer(),
          min: term(),
          max: term(),
          top: [{String.t(), pos_integer()}],
          bins: [non_neg_integer()]
        }

  @bins 10
  @top 3

  @numeric ~w(TINYINT SMALLINT INTEGER BIGINT HUGEINT UTINYINT USMALLINT UINTEGER UBIGINT
              UHUGEINT FLOAT DOUBLE)

  @doc "Whether a DuckDB type is a number."
  @spec numeric?(String.t()) :: boolean()
  def numeric?(type), do: type in @numeric or String.starts_with?(type, "DECIMAL")

  @doc "Whether a DuckDB type is a date, time or timestamp."
  @spec temporal?(String.t()) :: boolean()
  def temporal?(type), do: String.starts_with?(type, ["DATE", "TIME"])

  @doc "Every column's profile, in column order."
  @spec columns(Table.t()) :: [column()]
  def columns(%Table{db: db} = table) do
    schema = Table.schema(table)

    stats =
      Enum.flat_map(schema, fn {name, type} ->
        c = ident(name)
        range = if numeric?(type) or temporal?(type), do: ["min(#{c})", "max(#{c})"], else: []
        ["count(#{c})", "count(DISTINCT #{c})" | range]
      end)

    %{rows: [[total | values]]} =
      Table.query!(db, "SELECT #{Enum.join(["count(*)" | stats], ", ")} FROM #{Table.ref(table)}")

    {columns, []} =
      Enum.map_reduce(schema, values, fn {name, type}, values ->
        ranged = numeric?(type) or temporal?(type)
        {[count, distinct | rest], values} = Enum.split(values, if(ranged, do: 4, else: 2))
        [min, max] = if ranged, do: rest, else: [nil, nil]

        column = %{
          name: name,
          type: type,
          count: total,
          nulls: total - count,
          distinct: distinct,
          min: min,
          max: max,
          top: if(ranged, do: [], else: top(table, name)),
          bins: if(numeric?(type) and count > 0, do: bins(table, name, min == max), else: [])
        }

        {column, values}
      end)

    columns
  end

  defp top(%Table{db: db} = table, name) do
    c = ident(name)

    %{rows: rows} =
      Table.query!(db, """
      SELECT #{c}::VARCHAR AS v, count(*) AS k FROM #{Table.ref(table)}
      WHERE #{c} IS NOT NULL GROUP BY v ORDER BY k DESC, v LIMIT #{@top}
      """)

    Enum.map(rows, &List.to_tuple/1)
  end

  # Equal-width bins between the column's min and max; one bin when they
  # are the same.
  defp bins(%Table{db: db} = table, name, single?) do
    c = ident(name)
    n = if single?, do: 1, else: @bins

    %{rows: rows} =
      Table.query!(db, """
      WITH s AS (SELECT min(#{c})::DOUBLE AS lo, max(#{c})::DOUBLE AS hi FROM #{Table.ref(table)})
      SELECT CASE WHEN s.hi = s.lo THEN 0
             ELSE least(floor((#{c}::DOUBLE - s.lo) / ((s.hi - s.lo) / #{n}))::BIGINT, #{n - 1}) END AS b,
             count(*)
      FROM #{Table.ref(table)}, s WHERE #{c} IS NOT NULL GROUP BY b
      """)

    counts = Map.new(rows, fn [b, k] -> {b, k} end)
    for b <- 0..(n - 1), do: Map.get(counts, b, 0)
  end
end
