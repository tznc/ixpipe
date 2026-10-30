defmodule IxpipeCore.Tools.Union do
  @moduledoc "Stacks the rows of `a` then `b`. Their columns must match by name."
  @behaviour IxpipeCore.Tool

  @impl true
  def inputs, do: ["a", "b"]

  @impl true
  def fields, do: []

  @impl true
  def run(%{"a" => a, "b" => b}, _config), do: Explorer.DataFrame.concat_rows(a, b)
end
