defmodule IxpipeCore.Tools do
  @moduledoc "The registry of tools a workflow's `tool:` key can name."

  @tools %{
    "input_csv" => IxpipeCore.Tools.InputCsv,
    "output_csv" => IxpipeCore.Tools.OutputCsv,
    "select" => IxpipeCore.Tools.Select,
    "filter" => IxpipeCore.Tools.Filter,
    "formula" => IxpipeCore.Tools.Formula,
    "sort" => IxpipeCore.Tools.Sort,
    "join" => IxpipeCore.Tools.Join,
    "summarize" => IxpipeCore.Tools.Summarize
  }

  @spec lookup(term()) :: module() | nil
  def lookup(name), do: Map.get(@tools, name)

  @names Map.new(@tools, fn {name, module} -> {module, name} end)

  @spec name(module()) :: String.t()
  def name(module), do: Map.fetch!(@names, module)
end
