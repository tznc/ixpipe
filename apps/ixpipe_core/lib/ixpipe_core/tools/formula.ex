defmodule IxpipeCore.Tools.Formula do
  @moduledoc """
  Computes columns from Polars SQL expressions. Config: `formulas`, a list of
  `{as, expr}` applied in order, so each sees the columns before it. An `as`
  naming an existing column replaces it in place. The input is the table `df`.
  """
  @behaviour IxpipeCore.Tool

  alias Explorer.DataFrame

  @impl true
  def inputs, do: ["in"]

  @impl true
  def required_config, do: ["formulas"]

  @impl true
  def run(%{"in" => df}, %{"formulas" => formulas}) do
    Enum.reduce(formulas, df, fn %{"as" => as, "expr" => expr}, df ->
      column = "(#{expr}) AS #{quote_name(as)}"

      if as in DataFrame.names(df),
        do: DataFrame.sql(df, "SELECT * REPLACE (#{column}) FROM df"),
        else: DataFrame.sql(df, "SELECT *, #{column} FROM df")
    end)
  end

  defp quote_name(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")
end
