defmodule IxpipeCore.Tools.InputCsv do
  @moduledoc "Reads a CSV file. Config: `path`."
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.Context
  import IxpipeCore.Duck, only: [literal: 1]

  @impl true
  def inputs, do: []

  @impl true
  def fields,
    do: [
      %{
        key: "path",
        label: "File",
        type: :path,
        accept: ["csv"],
        hint: "A CSV file on this computer"
      }
    ]

  @impl true
  def run(_inputs, %{"path" => path}, ctx),
    do: Context.sql(ctx, "SELECT * FROM read_csv(#{literal(path)})")
end
