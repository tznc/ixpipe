defmodule IxpipeCore.Tools.CrossTab do
  @moduledoc """
  Pivots long data wide: each value of the `header` column becomes a column
  holding `value` aggregated by `method` (#{inspect(~w(sum mean min max count first))},
  default `sum`) for each `group_by` group. Missing combinations are empty.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @methods %{
    "sum" => "sum",
    "mean" => "avg",
    "min" => "min",
    "max" => "max",
    "count" => "count",
    "first" => "first"
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
  def run(
        %{"in" => t},
        %{"group_by" => group_by, "header" => header, "value" => value} = config,
        ctx
      ) do
    aggregate = Map.fetch!(@methods, config["method"] || "sum")
    groups = Enum.map_join(group_by, ", ", &ident/1)

    # Aggregate first, then pivot each group's one value per header, so a
    # missing combination is NULL (PIVOT's own count would give 0). Column
    # names are text, whatever the header column holds.
    Context.sql(ctx, """
    PIVOT (
      SELECT #{groups}, CAST(#{ident(header)} AS VARCHAR) AS __header,
        #{aggregate}(#{ident(value)}) AS __value
      FROM #{Table.ref(t)} GROUP BY ALL
    ) ON __header USING first(__value) GROUP BY #{groups}
    """)
  end
end
