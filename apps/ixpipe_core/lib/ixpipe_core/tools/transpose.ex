defmodule IxpipeCore.Tools.Transpose do
  @moduledoc """
  Pivots wide data long: each of `columns` (default: every column not in
  `keys`) becomes rows of `name` and `value`, beside the `keys` columns.
  Values of mixed types become text.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "keys", label: "Key columns", type: :list, hint: "Columns to keep on every row"},
      %{
        key: "columns",
        label: "Data columns",
        type: :list,
        hint: "Leave empty for every other column",
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => t}, %{"keys" => keys} = config, ctx) do
    columns = config["columns"] || Table.columns(t) -- keys
    types = Table.dtypes(t)

    cast =
      if columns |> Enum.map(&types[&1]) |> Enum.uniq() |> length() > 1,
        do: &"CAST(#{ident(&1)} AS VARCHAR) AS #{ident(&1)}",
        else: &ident/1

    select = Enum.map(keys, &ident/1) ++ Enum.map(columns, cast)
    on = Enum.map_join(columns, ", ", &ident/1)

    # INCLUDE NULLS keeps empty cells as rows, as a pivot longer does.
    Context.sql(ctx, """
    SELECT * FROM (SELECT #{Enum.join(select, ", ")} FROM #{Table.ref(t)})
    UNPIVOT INCLUDE NULLS (value FOR name IN (#{on}))
    """)
  end
end
