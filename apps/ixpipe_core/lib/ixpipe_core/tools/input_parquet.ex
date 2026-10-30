defmodule IxpipeCore.Tools.InputParquet do
  @moduledoc "Reads a Parquet file. Config: `path`."
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
        accept: ["parquet"],
        hint: "A Parquet file on this computer"
      }
    ]

  @impl true
  def run(_inputs, %{"path" => path}), do: Explorer.DataFrame.from_parquet!(path)
end
