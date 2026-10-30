defmodule IxpipeCore.Tools.Filter do
  @moduledoc """
  Splits rows on a DuckDB SQL condition: `true` gets the rows where it holds,
  `false` the rest (including rows where it is NULL). Config: `expr`, such
  as `amount > 10 AND region = 'eu'`. The input is the table `df`.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{
        key: "expr",
        label: "Condition",
        type: :expr,
        hint: "A SQL condition, e.g. amount > 10 AND region = 'eu'"
      }
    ]

  @impl true
  def outputs, do: ["true", "false"]

  @impl true
  def run(%{"in" => t}, %{"expr" => expr}, ctx) do
    # The input is also the table `df`, for subqueries.
    df = "WITH df AS (SELECT * FROM #{Table.ref(t)}) SELECT * FROM df"

    %{
      "true" => Context.sql(ctx, "true", "#{df} WHERE (#{expr})"),
      "false" => Context.sql(ctx, "false", "#{df} WHERE NOT COALESCE((#{expr}), FALSE)")
    }
  end
end
