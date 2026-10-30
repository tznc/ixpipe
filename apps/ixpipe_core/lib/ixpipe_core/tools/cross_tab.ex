defmodule IxpipeCore.Tools.CrossTab do
  @moduledoc """
  Pivots long data wide: each value of the `header` column becomes a column
  holding `value` aggregated by `method` (#{inspect(~w(sum mean min max count first))},
  default `sum`) for each `group_by` group. Missing combinations are empty.
  """
  @behaviour IxpipeCore.Tool

  alias Explorer.{DataFrame, Series}

  @methods %{
    "sum" => &Series.sum/1,
    "mean" => &Series.mean/1,
    "min" => &Series.min/1,
    "max" => &Series.max/1,
    "count" => &Series.count/1,
    "first" => &Series.first/1
  }

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "group_by", label: "Group by", type: :list, hint: "Comma-separated columns"},
      %{
        key: "header",
        label: "New columns from",
        type: :string,
        hint: "A column whose values name the new columns"
      },
      %{key: "value", label: "Values from", type: :string, hint: "A column to aggregate"},
      %{
        key: "method",
        label: "Method",
        type: :choice,
        options: ~w(sum mean min max count first),
        default: "sum",
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => df}, %{"group_by" => group_by, "header" => header, "value" => value} = config) do
    aggregate = Map.fetch!(@methods, config["method"] || "sum")
    # Column names are text, whatever the header column holds.
    df = DataFrame.put(df, header, Series.cast(df[header], :string))

    df
    |> DataFrame.group_by(group_by ++ [header])
    |> DataFrame.summarise_with(fn ldf -> [{value, aggregate.(ldf[value])}] end)
    |> DataFrame.pivot_wider(header, value, id_columns: group_by)
  end
end
