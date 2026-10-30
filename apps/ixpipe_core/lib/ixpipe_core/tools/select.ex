defmodule IxpipeCore.Tools.Select do
  @moduledoc "Keeps the listed columns, in order. Config: `columns`."
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
        hint: "Comma-separated, in the order to keep"
      }
    ]

  @impl true
  def run(%{"in" => t}, %{"columns" => columns}, ctx),
    do: Context.sql(ctx, "SELECT #{Enum.map_join(columns, ", ", &ident/1)} FROM #{Table.ref(t)}")
end
