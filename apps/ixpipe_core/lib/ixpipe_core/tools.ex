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
    "input_json" => IxpipeCore.Tools.InputJson,
    "output_json" => IxpipeCore.Tools.OutputJson,
    "input_sqlite" => IxpipeCore.Tools.InputSqlite,
    "output_sqlite" => IxpipeCore.Tools.OutputSqlite,
    "input_postgres" => IxpipeCore.Tools.InputPostgres,
    "output_postgres" => IxpipeCore.Tools.OutputPostgres,
    "input_mysql" => IxpipeCore.Tools.InputMysql,
    "output_mysql" => IxpipeCore.Tools.OutputMysql,
    "input_sqlserver" => IxpipeCore.Tools.InputSqlserver,
    "output_sqlserver" => IxpipeCore.Tools.OutputSqlserver,
    "input_bigquery" => IxpipeCore.Tools.InputBigquery,
    "cross_tab" => IxpipeCore.Tools.CrossTab,
    "transpose" => IxpipeCore.Tools.Transpose,
    "text_to_columns" => IxpipeCore.Tools.TextToColumns,
    "regex" => IxpipeCore.Tools.Regex,
    "data_cleansing" => IxpipeCore.Tools.DataCleansing,
    "record_id" => IxpipeCore.Tools.RecordId,
    "running_total" => IxpipeCore.Tools.RunningTotal,
    "tile" => IxpipeCore.Tools.Tile,
    "generate_rows" => IxpipeCore.Tools.GenerateRows,
    "imputation" => IxpipeCore.Tools.Imputation,
    "auto_field" => IxpipeCore.Tools.AutoField,
    "find_replace" => IxpipeCore.Tools.FindReplace,
    "append_fields" => IxpipeCore.Tools.AppendFields,
    "join_multiple" => IxpipeCore.Tools.JoinMultiple,
    "fuzzy_match" => IxpipeCore.Tools.FuzzyMatch
  }

  @spec lookup(term()) :: module() | nil
  def lookup(name), do: Map.get(@tools, name)

  @names Map.new(@tools, fn {name, module} -> {module, name} end)

  @doc "A tool's output names; `[\"out\"]` unless it declares several."
  @spec outputs(module()) :: [String.t()]
  def outputs(tool) do
    Code.ensure_loaded(tool)
    if function_exported?(tool, :outputs, 0), do: tool.outputs(), else: ["out"]
  end

  @doc "The input ports a node of `tool` may leave unconnected; `[]` unless it declares some."
  @spec optional_inputs(module()) :: [String.t()]
  def optional_inputs(tool) do
    Code.ensure_loaded(tool)
    if function_exported?(tool, :optional_inputs, 0), do: tool.optional_inputs(), else: []
  end

  @spec name(module()) :: String.t()
  def name(module), do: Map.fetch!(@names, module)

  @doc "Every tool name, sorted."
  @spec names() :: [String.t()]
  def names, do: @tools |> Map.keys() |> Enum.sort()

  @doc "The config keys `tool` cannot run without: its non-optional fields."
  @spec required(module()) :: [String.t()]
  def required(tool), do: for(field <- tool.fields(), !field[:optional], do: field.key)
end
