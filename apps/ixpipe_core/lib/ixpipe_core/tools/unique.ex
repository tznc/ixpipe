defmodule IxpipeCore.Tools.Unique do
  @moduledoc """
  Drops repeated rows, keeping the first. Config: optional `columns` to
  compare; without it, whole rows are compared.
  """
  @behaviour IxpipeCore.Tool

  alias Explorer.DataFrame

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
  def run(%{"in" => df}, config) do
    columns = config["columns"] || DataFrame.names(df)
    DataFrame.distinct(df, columns, keep_all: true)
  end
end
