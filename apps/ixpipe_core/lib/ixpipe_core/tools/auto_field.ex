defmodule IxpipeCore.Tools.AutoField do
  @moduledoc """
  Gives each text (VARCHAR) column of `in` the narrowest type every value
  fits, as Alteryx's Auto Field: BIGINT, DOUBLE, DATE, TIMESTAMP, BOOLEAN,
  else VARCHAR, tried in that order with `TRY_CAST` on the trimmed values.
  Blank values become null and fit any type; a column of only blanks stays
  VARCHAR, as does a numeric-looking one with a leading zero (`02134`), so
  codes keep their digits. Config: optional `columns` (default every
  VARCHAR column); other columns pass through unchanged.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @types ~w(BIGINT DOUBLE DATE TIMESTAMP BOOLEAN)

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{
        key: "columns",
        label: "Columns",
        type: :list,
        hint: "Leave empty for every text column",
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => t}, config, ctx) do
    types = Table.dtypes(t)
    all = Table.columns(t)
    columns = Enum.filter(config["columns"] || all, &(types[&1] == "VARCHAR"))

    case columns do
      [] ->
        Context.sql(ctx, "SELECT * FROM #{Table.ref(t)} ORDER BY rowid")

      _ ->
        fits = fits(t, columns)

        casts =
          for c <- columns, type = fits[c], type != "VARCHAR" do
            "TRY_CAST(#{value(ident(c))} AS #{type}) AS #{ident(c)}"
          end

        select = if casts == [], do: "*", else: "* REPLACE (#{Enum.join(casts, ", ")})"
        Context.sql(ctx, "SELECT #{select} FROM #{Table.ref(t)} ORDER BY rowid")
    end
  end

  defp value(c), do: "nullif(trim(#{c}), '')"

  # TRY_CAST alone is too forgiving: it rounds 2.5 to a BIGINT and drops
  # a timestamp's time to make a DATE.
  defp fits?(v, "BIGINT"),
    do: "regexp_matches(#{v}, '^[-+]?[0-9]+$') AND TRY_CAST(#{v} AS BIGINT) IS NOT NULL"

  defp fits?(v, "DATE"),
    do: "NOT regexp_matches(#{v}, '[0-9]:[0-9]') AND TRY_CAST(#{v} AS DATE) IS NOT NULL"

  defp fits?(v, type), do: "TRY_CAST(#{v} AS #{type}) IS NOT NULL"

  # For each column, the first type every present value casts to, from one
  # scan: a count of the values each type rejects.
  defp fits(t, columns) do
    checks =
      for c <- columns, type <- ["PRESENT", "LEADING_ZERO" | @types] do
        v = value(ident(c))

        case type do
          "PRESENT" -> "count(#{v})"
          "LEADING_ZERO" -> "count(*) FILTER (WHERE regexp_matches(#{v}, '^[-+]?0[0-9]'))"
          type -> "count(*) FILTER (WHERE #{v} IS NOT NULL AND NOT (#{fits?(v, type)}))"
        end
      end

    %{rows: [counts]} =
      Table.query!(t.db, "SELECT #{Enum.join(checks, ", ")} FROM #{Table.ref(t)}")

    columns
    |> Enum.zip(Enum.chunk_every(counts, length(@types) + 2))
    |> Map.new(fn {c, [present, leading_zero | rejects]} ->
      numeric = if leading_zero > 0, do: ~w(DATE TIMESTAMP BOOLEAN), else: @types

      fit =
        if present == 0,
          do: "VARCHAR",
          else:
            @types
            |> Enum.zip(rejects)
            |> Enum.find_value("VARCHAR", fn {type, n} ->
              if n == 0 and type in numeric, do: type
            end)

      {c, fit}
    end)
  end
end
