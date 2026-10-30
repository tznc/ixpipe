defmodule IxpipeCore.Tools.Filter do
  @moduledoc """
  Splits rows on a Polars SQL condition: `true` gets the rows where it holds,
  `false` the rest (including rows where it is NULL). Config: `expr`, such
  as `amount > 10 AND region = 'eu'`. The input is the table `df`.
  """
  @behaviour IxpipeCore.Tool

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
  def run(%{"in" => df}, %{"expr" => expr}) do
    %{
      "true" => Explorer.DataFrame.sql(df, "SELECT * FROM df WHERE (#{expr})"),
      "false" =>
        Explorer.DataFrame.sql(df, "SELECT * FROM df WHERE NOT COALESCE((#{expr}), FALSE)")
    }
  end
end
