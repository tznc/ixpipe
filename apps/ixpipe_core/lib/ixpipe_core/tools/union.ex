defmodule IxpipeCore.Tools.Union do
  @moduledoc "Stacks the rows of `a` then `b`. Their columns must match by name."
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}

  @impl true
  def inputs, do: ["a", "b"]

  @impl true
  def fields, do: []

  @impl true
  def run(%{"a" => a, "b" => b}, _config, ctx),
    do:
      Context.sql(
        ctx,
        "SELECT * FROM #{Table.ref(a)} UNION ALL BY NAME SELECT * FROM #{Table.ref(b)}"
      )
end
