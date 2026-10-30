defmodule IxpipeCore.Tools.Filter do
  @moduledoc """
  Keeps rows where a Polars SQL expression is true. Config: `expr`, such as
  `amount > 10 AND region = 'eu'`. The input is the table `df`.
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
  def run(%{"in" => df}, %{"expr" => expr}),
    do: Explorer.DataFrame.sql(df, "SELECT * FROM df WHERE (#{expr})")
end
