defmodule IxpipeCore.Tools.InputCsv do
  @moduledoc """
  Reads CSV files: `path` is a file, a folder (every .csv file in it) or a
  wildcard pattern, local or in cloud storage (see `IxpipeCore.Cloud`, and
  the optional `connection`). Files are unioned by column name; with
  `filename`, a `filename` column says which file each row came from.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.Files

  @impl true
  def inputs, do: []

  @impl true
  def fields, do: Files.input_fields("CSV", "csv")

  @impl true
  def run(_inputs, config, ctx), do: Files.read(ctx, "read_csv", "csv", config)
end
