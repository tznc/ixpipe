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
    Context.sql(ctx, "WITH df AS (SELECT * FROM #{Table.ref(t)}) #{select}")
  end
end
