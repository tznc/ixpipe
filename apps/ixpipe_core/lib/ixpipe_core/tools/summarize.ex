defmodule IxpipeCore.Tools.Summarize do
  @moduledoc """
  Groups and aggregates. Config: `group_by` (columns) and `aggregates`, a list
  of `{column, op, as}` where `op` is one of #{inspect(~w(sum mean min max count n_distinct))}.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @ops %{
    "sum" => "sum",
    "mean" => "avg",
    "min" => "min",
    "max" => "max",
    "count" => "count",
    "n_distinct" => "count(DISTINCT"
  }

  @doc "The aggregate ops, by name."
  def ops, do: ~w(sum mean min max count n_distinct)

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "group_by", label: "Group by", type: :list, hint: "Comma-separated columns"},
      %{
        key: "aggregates",
        label: "Aggregates",
        type: :aggregates,
        hint: "e.g. sum(amount) as total, count(id) as orders"
      }
    ]

  @impl true
  def run(%{"in" => t}, %{"group_by" => group_by, "aggregates" => aggregates}, ctx) do
    aggs =
      Enum.map_join(aggregates, ", ", fn %{"column" => c, "op" => op, "as" => as} ->
        "#{aggregate(Map.fetch!(@ops, op), ident(c))} AS #{ident(as)}"
      end)

    case group_by do
      [] ->
        Context.sql(ctx, "SELECT #{aggs} FROM #{Table.ref(t)}")

      _ ->
        groups = Enum.map_join(group_by, ", ", &ident/1)

        Context.sql(
          ctx,
          "SELECT #{groups}, #{aggs} FROM #{Table.ref(t)} GROUP BY #{groups} ORDER BY #{groups}"
        )
    end
  end

  defp aggregate("count(DISTINCT", column), do: "count(DISTINCT #{column})"
  defp aggregate(fun, column), do: "#{fun}(#{column})"
end
