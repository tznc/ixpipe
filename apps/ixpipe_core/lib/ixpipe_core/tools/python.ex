defmodule IxpipeCore.Tools.Python do
  @moduledoc """
  Runs a Python script in ixpipe's sandbox (`IxpipeCore.Python`): no system
  Python, files, network or processes, on desktop and Android. The script
  reads `inputs["in"]` (rows as dicts) and sets `output`. Outputs: `out`, the
  script's table, and `log`, its printed lines and warnings. Config: `code`,
  optional `row_limit`, `time_limit` (seconds) and `memory_limit` (MB).
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.Tools.Code

  @time_limit 30
  @memory_limit 256

  @impl true
  def inputs, do: ["in"]

  @impl true
  def outputs, do: ["out", "log"]

  @impl true
  def fields,
    do: [
      %{
        key: "code",
        label: "Script",
        type: :code,
        hint:
          ~s|Rows are in inputs["in"], a list of dicts. Set output to a list of dicts or a dict of columns.|
      },
      Code.row_limit_field(),
      %{
        key: "time_limit",
        label: "Time limit (seconds)",
        type: :integer,
        optional: true,
        default: @time_limit,
        hint: "CPU time the script may use"
      },
      %{
        key: "memory_limit",
        label: "Memory limit (MB)",
        type: :integer,
        optional: true,
        default: @memory_limit
      }
    ]

  @impl true
  def run(%{"in" => t}, %{"code" => code} = config, ctx) do
    {data, warnings} = Code.cut(t, config["row_limit"], "in")

    opts = [
      timeout: (config["time_limit"] || @time_limit) * 1000,
      memory: (config["memory_limit"] || @memory_limit) * 1024 * 1024
    ]

    case IxpipeCore.Python.run(code, %{"in" => data}, opts) do
      {:ok, %{columns: columns, rows: rows, stdout: stdout}} ->
        %{"out" => Code.output(ctx, columns, rows), "log" => Code.log(ctx, warnings, stdout)}

      {:error, %{kind: :exception, message: message, traceback: traceback}} ->
        raise "#{message} Fix the script and run again.\n\n#{String.trim_trailing(traceback)}"

      {:error, %{message: message}} ->
        raise message
    end
  end
end
