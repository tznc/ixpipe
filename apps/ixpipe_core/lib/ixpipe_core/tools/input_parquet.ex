defmodule IxpipeCore.Tools.InputParquet do
  @moduledoc "Reads a Parquet file. Config: `path`."
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
        accept: ["parquet"],
        hint: "A Parquet file on this computer"
      }
    ]

  @impl true
  def run(_inputs, %{"path" => path}, ctx),
    do: Context.sql(ctx, "SELECT * FROM read_parquet(#{literal(path)})")
end
