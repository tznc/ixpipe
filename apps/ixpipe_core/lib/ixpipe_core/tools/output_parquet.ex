defmodule IxpipeCore.Tools.OutputParquet do
  @moduledoc "Writes its input to a Parquet file and passes it through. Config: `path`."
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
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
        accept: ["parquet"],
        save: true,
        hint: "Where to write the Parquet file"
      }
    ]

  @impl true
  def run(%{"in" => t}, %{"path" => path}, ctx) do
    Table.exec!(t.db, "COPY #{Table.ref(t)} TO #{literal(path)} (FORMAT parquet)")
    Context.info(ctx, "Wrote #{IxpipeCore.plural(Table.count(t), "row")} to #{path}.")
    t
  end
end
