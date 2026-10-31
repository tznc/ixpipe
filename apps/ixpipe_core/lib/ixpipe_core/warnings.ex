defmodule IxpipeCore.Warnings do
  @moduledoc "Checks tools share, recording warnings in the node's `IxpipeCore.Context`."

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @doc """
  Warns about each text column whose values are mostly numbers: a few
  values that aren't (say "n/a") made the whole column text, so sums and
  comparisons won't work on it.
  """
  @spec numbers_as_text(Context.t(), Table.t()) :: :ok
  def numbers_as_text(ctx, table) do
    texts = for {col, "VARCHAR"} <- Table.dtypes(table), do: col

    if texts != [] do
      selects =
        Enum.map_join(texts, ", ", fn col ->
          c = ident(col)
          bad = "#{c} IS NOT NULL AND TRY_CAST(#{c} AS DOUBLE) IS NULL"
          "count(#{c}), count(TRY_CAST(#{c} AS DOUBLE)), first(#{c}) FILTER (WHERE #{bad})"
        end)

      %{rows: [row]} = Table.query!(table.db, "SELECT #{selects} FROM #{Table.ref(table)}")

      for {col, [values, numbers, example]} <- Enum.zip(texts, Enum.chunk_every(row, 3)),
          numbers > 0 and numbers * 2 >= values and numbers < values do
        bad = values - numbers
        what = if bad == 1, do: "isn't a number", else: "aren't numbers"

        Context.warn(
          ctx,
          ~s|Column "#{col}" is read as text: #{bad} of #{values} values #{what} ("#{example}"). | <>
            "Clean them with Data cleansing, or convert with a Formula: TRY_CAST(#{ident(col)} AS DOUBLE)."
        )
      end
    end

    :ok
  end
end
