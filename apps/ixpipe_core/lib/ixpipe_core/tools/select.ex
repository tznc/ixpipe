defmodule IxpipeCore.Tools.Select do
  @moduledoc "Keeps the listed columns, in order. Config: `columns`."
  @behaviour IxpipeCore.Tool

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
  def run(%{"in" => df}, %{"columns" => columns}), do: Explorer.DataFrame.select(df, columns)
end
