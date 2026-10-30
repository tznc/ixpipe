defmodule IxpipeCore.Tools.OutputParquet do
  @moduledoc """
  Writes its input to a Parquet file, local or in cloud storage (see
  `IxpipeCore.Cloud`), and passes it through. Config: `path`, optional
  `connection`.
  """
  @behaviour IxpipeCore.Tool

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields, do: IxpipeCore.Files.output_fields("Parquet", "parquet")

  @impl true
  def run(%{"in" => t}, config, _ctx), do: IxpipeCore.Files.write(t, config, "FORMAT parquet")
end
