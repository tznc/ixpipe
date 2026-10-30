defmodule IxpipeCore.Tools.OutputCsv do
  @moduledoc """
  Writes its input to a CSV file, local or in cloud storage (see
  `IxpipeCore.Cloud`), and passes it through. Config: `path`, optional
  `connection`.
  """
  @behaviour IxpipeCore.Tool

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields, do: IxpipeCore.Files.output_fields("CSV", "csv")

  @impl true
  def run(%{"in" => t}, config, _ctx), do: IxpipeCore.Files.write(t, config, "HEADER")
end
