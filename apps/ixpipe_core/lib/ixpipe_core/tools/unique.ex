defmodule IxpipeCore.Tools.Unique do
  @moduledoc """
  Drops repeated rows, keeping the first. Config: optional `columns` to
  compare; without it, whole rows are compared.
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
        key: "columns",
        label: "Columns",
        type: :list,
        hint: "Leave empty to compare whole rows",
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => t}, config, ctx) do
    columns = config["columns"] || Table.columns(t)
    keys = Enum.map_join(columns, ", ", &ident/1)

    # The first row of each key, in table order.
    Context.sql(ctx, """
    SELECT * EXCLUDE (__row) FROM (SELECT *, row_number() OVER () AS __row FROM #{Table.ref(t)})
    QUALIFY row_number() OVER (PARTITION BY #{keys} ORDER BY __row) = 1
    ORDER BY __row
    """)
  end
end
