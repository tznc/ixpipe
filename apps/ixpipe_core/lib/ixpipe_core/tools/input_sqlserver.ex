defmodule IxpipeCore.Tools.InputSqlserver do
  @moduledoc """
  Reads from Microsoft SQL Server through a saved `connection` (see
  `IxpipeCore.Connections`): a `query`, or every row of a `table`.
  Decimals become floats, timestamps naive UTC, JSON text.
  """
  @behaviour IxpipeCore.Tool

  @impl true
  def inputs, do: []

  @impl true
  def fields, do: IxpipeCore.Server.input_fields("sqlserver")

  @impl true
  def run(_inputs, config, ctx), do: IxpipeCore.Server.read("sqlserver", config, ctx)
end
