defmodule IxpipeCore.Tools.OutputParquet do
  @moduledoc "Writes its input to a Parquet file and passes it through. Config: `path`."
  @behaviour IxpipeCore.Tool

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{
        key: "path",
        label: "File",
        type: :path,
        accept: ["parquet"],
        save: true,
        hint: "Where to write the Parquet file"
      }
    ]

  @impl true
  def run(%{"in" => df}, %{"path" => path}) do
    Explorer.DataFrame.to_parquet!(df, path)
    df
  end
end
