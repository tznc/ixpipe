defmodule IxpipeCore.Tools.OutputCsv do
  @moduledoc "Writes its input to a CSV file and passes it through. Config: `path`."
  @behaviour IxpipeCore.Tool

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [%{key: "path", label: "File", type: :path, hint: "Where to write the CSV"}]

  @impl true
  def run(%{"in" => df}, %{"path" => path}) do
    Explorer.DataFrame.to_csv!(df, path)
    df
  end
end
