defmodule IxpipeCore.Tools.OutputPostgres do
  @moduledoc """
  Writes its input to a PostgreSQL `table` through a saved `connection`,
  replacing the table (`mode` replace, the default) or appending to it,
  and passes the input through. Column types follow DuckDB's
  (`IxpipeCore.Server.column_type/2`); rows load with `COPY`.
  """
  @behaviour IxpipeCore.Tool

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields, do: IxpipeCore.Server.output_fields("postgres")

  @impl true
  def run(%{"in" => t}, config, _ctx), do: IxpipeCore.Server.write("postgres", t, config)
end
