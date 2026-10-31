defmodule IxpipeCore.Tools.Imputation do
  @moduledoc """
  Fills missing values in numeric `columns` of `in`, as Alteryx's
  Imputation. Missing means null, or with `missing` set, that value
  instead. `method` fills with the `mean`, `median` or `mode` of the
  column's other (present, non-null) values, or a `constant` (`value`).
  Filled columns are DOUBLE. With `indicator`, each column gets a
  `<column>_imputed` BOOLEAN column, true where a value was filled.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @numeric ~w(TINYINT SMALLINT INTEGER BIGINT HUGEINT UTINYINT USMALLINT UINTEGER UBIGINT
              UHUGEINT FLOAT DOUBLE)

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "columns", label: "Columns", type: :list, hint: "Numeric columns to fill"},
      %{key: "method", label: "Fill with", type: :choice, options: ~w(mean median mode constant)},
      %{
        key: "value",
        label: "Constant",
        type: :string,
        hint: "For Fill with constant",
        optional: true
      },
      %{
        key: "missing",
        label: "Value to replace",
        type: :string,
        hint: "Leave empty to replace nulls",
        optional: true
      },
      %{
        key: "indicator",
        label: "Add indicator columns",
        type: :bool,
        default: false,
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => t}, %{"columns" => columns, "method" => method} = config, ctx) do
    types = Table.dtypes(t)

    for c <- columns do
      type =
        types[c] ||
          raise "#{c} is not a column. Choose one of: #{Enum.join(Map.keys(types), ", ")}."

      unless type in @numeric or String.starts_with?(type, "DECIMAL"),
        do: raise("#{c} is not numeric (#{type}). Choose numeric columns, or convert it first.")
    end

    missing = fn c ->
      case config["missing"] do
        nil -> "#{c} IS NULL"
        value -> "coalesce(#{c} = #{number!(value, "Value to replace")}, false)"
      end
    end

    fills =
      columns
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {c, i} ->
        c = ident(c)
        "#{fill(method, c, missing.(c), config)} AS __fill#{i}"
      end)

    replaced =
      columns
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {c, i} ->
        "CAST(CASE WHEN #{missing.("t." <> ident(c))} THEN s.__fill#{i} ELSE t.#{ident(c)} END AS DOUBLE) AS #{ident(c)}"
      end)

    indicators =
      if config["indicator"],
        do:
          Enum.map_join(
            columns,
            "",
            &", #{missing.("t." <> ident(&1))} AS #{ident(&1 <> "_imputed")}"
          ),
        else: ""

    Context.sql(ctx, """
    WITH s AS (SELECT #{fills} FROM #{Table.ref(t)})
    SELECT t.* REPLACE (#{replaced})#{indicators}
    FROM #{Table.ref(t)} t CROSS JOIN s ORDER BY t.rowid
    """)
  end

  defp fill("mean", c, missing, _), do: "avg(#{c}) FILTER (WHERE NOT (#{missing}))"
  defp fill("median", c, missing, _), do: "median(#{c}) FILTER (WHERE NOT (#{missing}))"
  defp fill("mode", c, missing, _), do: "mode(#{c}) FILTER (WHERE NOT (#{missing}))"

  defp fill("constant", _c, _missing, config) do
    value = config["value"] || raise "Fill with constant needs a Constant. Enter one."
    # An aggregate like the others, so the fills stay one row.
    "any_value(CAST(#{number!(value, "Constant")} AS DOUBLE))"
  end

  defp fill(method, _, _, _),
    do: raise("Unknown method #{method}. Choose mean, median, mode or constant.")

  defp number!(text, label) do
    text = String.trim(to_string(text))

    case Float.parse(text) do
      {_, ""} -> text
      _ -> raise "#{label} #{text} is not a number. Enter a number."
    end
  end
end
