defmodule IxpipeCore.Tools.InputJson do
  @moduledoc """
  Reads JSON files (an array of objects, one object, or one object per line): `path` is a file, a folder (every .json file in it) or a
  wildcard pattern, local or in cloud storage (see `IxpipeCore.Cloud`, and
  the optional `connection`). Files are unioned by column name; with
  `filename`, a `filename` column says which file each row came from.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.Files

  @impl true
  def inputs, do: []

  @impl true
  def fields, do: Files.input_fields("JSON", "json")

  @impl true
  def run(_inputs, config, ctx), do: Files.read(ctx, "read_json", "json", config)
end
