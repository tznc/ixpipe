defmodule IxpipeCore.Tools.InputCsv do
  @moduledoc "Reads a CSV file. Config: `path`."
  @behaviour IxpipeCore.Tool

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
  def run(_inputs, %{"path" => path}), do: Explorer.DataFrame.from_csv!(path)
end
