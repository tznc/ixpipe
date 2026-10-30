defmodule IxpipeCore.Tools.Summarize do
  @moduledoc """
  Groups and aggregates. Config: `group_by` (columns) and `aggregates`, a list
  of `{column, op, as}` where `op` is one of #{inspect(~w(sum mean min max count n_distinct))}.
  """
  @behaviour IxpipeCore.Tool

  alias Explorer.{DataFrame, Series}

  @ops %{
    "sum" => &Series.sum/1,
    "mean" => &Series.mean/1,
    "min" => &Series.min/1,
    "max" => &Series.max/1,
    "count" => &Series.count/1,
    "n_distinct" => &Series.n_distinct/1
  }

  @impl true
  def inputs, do: ["in"]

  @impl true
  def run(%{"in" => df}, %{"group_by" => group_by, "aggregates" => aggregates}) do
    df
    |> DataFrame.group_by(group_by)
    |> DataFrame.summarise_with(fn ldf ->
      for %{"column" => column, "op" => op, "as" => as} <- aggregates,
          do: {as, Map.fetch!(@ops, op).(ldf[column])}
    end)
  end
end
