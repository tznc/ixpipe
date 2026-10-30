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
    "summarize" => IxpipeCore.Tools.Summarize,
    "union" => IxpipeCore.Tools.Union,
    "sample" => IxpipeCore.Tools.Sample,
    "unique" => IxpipeCore.Tools.Unique,
    "input_excel" => IxpipeCore.Tools.InputExcel,
    "output_excel" => IxpipeCore.Tools.OutputExcel,
    "input_parquet" => IxpipeCore.Tools.InputParquet,
    "output_parquet" => IxpipeCore.Tools.OutputParquet,
    "input_sqlite" => IxpipeCore.Tools.InputSqlite,
    "output_sqlite" => IxpipeCore.Tools.OutputSqlite,
    "input_postgres" => IxpipeCore.Tools.InputPostgres,
    "cross_tab" => IxpipeCore.Tools.CrossTab,
    "transpose" => IxpipeCore.Tools.Transpose,
    "text_to_columns" => IxpipeCore.Tools.TextToColumns,
    "regex" => IxpipeCore.Tools.Regex,
    "data_cleansing" => IxpipeCore.Tools.DataCleansing,
    "macro_input" => IxpipeCore.Tools.MacroInput,
    "macro_output" => IxpipeCore.Tools.MacroOutput,
    "macro" => IxpipeCore.Tools.Macro
  }

  @spec lookup(term()) :: module() | nil
  def lookup(name), do: Map.get(@tools, name)

  @names Map.new(@tools, fn {name, module} -> {module, name} end)

  alias IxpipeCore.Spec.Node

  @doc """
  A node's input ports. A tool whose ports depend on the node (a macro)
  exports `inputs/1`; the rest `inputs/0`.
  """
  @spec inputs(Node.t()) :: [String.t()]
  def inputs(%Node{tool: tool} = node),
    do: if(exports?(tool, :inputs, 1), do: tool.inputs(node), else: tool.inputs())

  @doc "A tool's (or a node's) output names; `[\"out\"]` unless it declares several."
  @spec outputs(module() | Node.t()) :: [String.t()]
  def outputs(%Node{tool: tool} = node),
    do: if(exports?(tool, :outputs, 1), do: tool.outputs(node), else: outputs(tool))

  def outputs(tool),
    do: if(exports?(tool, :outputs, 0), do: tool.outputs(), else: ["out"])

  @doc "A node's settings: `fields/1` for a tool whose settings depend on the node."
  @spec fields(Node.t()) :: [IxpipeCore.Tool.field()]
  def fields(%Node{tool: tool} = node),
    do: if(exports?(tool, :fields, 1), do: tool.fields(node), else: tool.fields())

  defp exports?(tool, fun, arity) do
    Code.ensure_loaded(tool)
    function_exported?(tool, fun, arity)
  end

  @spec name(module()) :: String.t()
  def name(module), do: Map.fetch!(@names, module)

  @doc "Every tool name, sorted."
  @spec names() :: [String.t()]
  def names, do: @tools |> Map.keys() |> Enum.sort()

  @doc "The config keys a node (or a tool) cannot run without: its non-optional fields."
  @spec required(module() | Node.t()) :: [String.t()]
  def required(%Node{} = node), do: for(field <- fields(node), !field[:optional], do: field.key)
  def required(tool), do: for(field <- tool.fields(), !field[:optional], do: field.key)
end
