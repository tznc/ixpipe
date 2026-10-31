defmodule IxpipeCore.Tools.RunningTotal do
  @moduledoc """
  Adds the cumulative sum of each of `columns` down the rows of `in`, as
  `RunningTotal_<column>`, restarting for each group of the optional
  `group_by` columns. Rows keep their order; nulls add nothing.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "columns", label: "Columns to total", type: :list, hint: "Numeric columns"},
      %{
        key: "group_by",
        label: "Group by",
        type: :list,
        hint: "Restart the total for each group",
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => t}, %{"columns" => columns} = config, ctx) do
    partition =
      case config["group_by"] || [] do
        [] -> ""
        groups -> "PARTITION BY #{Enum.map_join(groups, ", ", &ident/1)} "
      end

    window = "(#{partition}ORDER BY rowid ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)"

    totals =
      Enum.map_join(columns, ", ", fn c ->
        "coalesce(sum(#{ident(c)}) OVER #{window}, 0) AS #{ident("RunningTotal_" <> c)}"
      end)

    Context.sql(ctx, "SELECT *, #{totals} FROM #{Table.ref(t)} ORDER BY rowid")
  end
end
