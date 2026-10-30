defmodule IxpipeCore.Tools.OutputSqlserver do
  @moduledoc """
  Writes its input to a SQL Server `table` through a saved `connection`,
  replacing the table (`mode` replace, the default) or appending to it,
  and passes the input through. Column types follow DuckDB's
  (`IxpipeCore.Server.column_type/2`); rows load in batched inserts.
  """
  @behaviour IxpipeCore.Tool

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields, do: IxpipeCore.Server.output_fields("sqlserver")

  @impl true
  def run(%{"in" => t}, config, _ctx), do: IxpipeCore.Server.write("sqlserver", t, config)
end
