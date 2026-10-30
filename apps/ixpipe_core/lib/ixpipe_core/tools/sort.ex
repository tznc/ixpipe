defmodule IxpipeCore.Tools.Sort do
  @moduledoc "Sorts by the listed columns. Config: `by`, optional `desc` (default false)."
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "by", label: "Sort by", type: :list, hint: "Comma-separated columns"},
      %{key: "desc", label: "Descending", type: :bool, optional: true}
    ]

  @impl true
  def run(%{"in" => t}, %{"by" => by} = config, ctx) do
    dir = if config["desc"], do: " DESC", else: ""
    order = Enum.map_join(by, ", ", &(ident(&1) <> dir))
    Context.sql(ctx, "SELECT * FROM #{Table.ref(t)} ORDER BY #{order}")
  end
end
