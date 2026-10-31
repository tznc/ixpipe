defmodule IxpipeCore.Tools.Formula do
  @moduledoc """
  Computes columns from DuckDB SQL expressions. Config: `formulas`, a list of
  `{as, expr}` applied in order, so each sees the columns before it. An `as`
  naming an existing column replaces it in place. The input is the table `df`.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{
        key: "formulas",
        label: "Formulas",
        type: :formulas,
        hint: "One per line: name = expression, e.g. taxed = amount * 1.1"
      }
    ]

  @impl true
  def run(%{"in" => t}, %{"formulas" => formulas}, ctx) do
    # Each formula sees the columns before it: one nested SELECT per formula.
    {select, _columns} =
      Enum.reduce(formulas, {"SELECT * FROM df", Table.columns(t)}, fn
        %{"as" => as, "expr" => expr}, {select, columns} ->
          column = "(#{expr}) AS #{ident(as)}"

          if as in columns,
            do: {"SELECT * REPLACE (#{column}) FROM (#{select})", columns},
            else: {"SELECT *, #{column} FROM (#{select})", columns ++ [as]}
      end)

    # The input is also the table `df`, for subqueries.
    out = Context.sql(ctx, "WITH df AS (SELECT * FROM #{Table.ref(t)}) #{select}")
    warn_all_null(ctx, out, formulas |> Enum.map(& &1["as"]) |> Enum.uniq())
    out
  end

  # A formula NULL on every row usually reads a NULL column or mixes types.
  defp warn_all_null(_ctx, _out, []), do: :ok

  defp warn_all_null(ctx, out, names) do
    counts = Enum.map_join(names, ", ", &"count(#{ident(&1)})")

    %{rows: [[total | counts]]} =
      Table.query!(out.db, "SELECT count(*), #{counts} FROM #{Table.ref(out)}")

    for {name, 0} <- Enum.zip(names, counts), total > 0 do
      Context.warn(
        ctx,
        ~s(Formula "#{name}" is NULL on every row. ) <>
          "Check the columns it uses have values, or give missing ones a default with COALESCE."
      )
    end

    :ok
  end
end
