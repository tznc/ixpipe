defmodule IxpipeCore.Tools.OutputCsv do
  @moduledoc "Writes its input to a CSV file and passes it through. Config: `path`."
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.Table
  import IxpipeCore.Duck, only: [literal: 1]

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{
        key: "path",
        label: "File",
        type: :path,
        accept: ["csv"],
        save: true,
        hint: "Where to write the CSV"
      }
    ]

  @impl true
  def run(%{"in" => t}, %{"path" => path}, _ctx) do
    Table.exec!(t.db, "COPY #{Table.ref(t)} TO #{literal(path)} (HEADER)")
    t
  end
end
