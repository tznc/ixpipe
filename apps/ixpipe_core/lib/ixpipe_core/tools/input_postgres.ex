defmodule IxpipeCore.Tools.InputPostgres do
  @moduledoc """
  Reads from PostgreSQL through a saved `connection` (see
  `IxpipeCore.Connections`): a `query`, or every row of a `table`. Numerics
  become floats, timestamps naive UTC, UUIDs and JSON text.
  """
  @behaviour IxpipeCore.Tool

  @impl true
  def inputs, do: []

  @impl true
  def fields, do: IxpipeCore.Server.input_fields("postgres")

  @impl true
  def run(_inputs, config, ctx), do: IxpipeCore.Server.read("postgres", config, ctx)
end
