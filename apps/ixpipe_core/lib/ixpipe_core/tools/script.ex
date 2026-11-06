defmodule IxpipeCore.Tools.Script do
  @moduledoc """
  Runs code in a language installed on this computer (`IxpipeCore.Script`):
  Python with the user's own packages, JavaScript on Node, Ruby or PHP.
  Unsandboxed, like Alteryx's Python and R tools; desktop only. Outputs:
  `out`, the script's table, and `log`, its stdout, stderr and warnings.

  Config: `language`, `code`, optional `interpreter` (an executable, such as
  a virtualenv's python), `format` (`json`: rows as the language's lists
  and maps; `parquet`: file paths, for pandas or Arrow), `row_limit` and
  `time_limit` (seconds).
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Script, Table}
  alias IxpipeCore.Tools.Code
  import IxpipeCore.Duck, only: [literal: 1]

  @time_limit 300

  @impl true
  def inputs, do: ["in"]

  @impl true
  def outputs, do: ["out", "log"]

  @impl true
  def fields,
    do: [
      %{
        key: "language",
        label: "Language",
        type: :choice,
        options: Script.languages(),
        optional: true,
        default: "python"
      },
      %{
        key: "code",
        label: "Script",
        type: :code,
        hint: ~s|Rows are in inputs["in"]. Set output to a list of rows or a table of columns.|
      },
      %{
        key: "interpreter",
        label: "Interpreter",
        type: :path,
        optional: true,
        hint:
          "Leave empty for python3, node, ruby or php on PATH, or choose one, such as a virtualenv's python"
      },
      %{
        key: "format",
        label: "Data format",
        type: :choice,
        options: ["json", "parquet"],
        optional: true,
        default: "json",
        hint: "json: rows as lists and maps. parquet: file paths, for pandas or Arrow"
      },
      Code.row_limit_field(),
      %{
        key: "time_limit",
        label: "Time limit (seconds)",
        type: :integer,
        optional: true,
        default: @time_limit
      }
    ]

  @impl true
  def run(%{"in" => t}, %{"code" => code} = config, ctx) do
    language = config["language"] || "python"
    parquet? = config["format"] == "parquet"
    dir = Path.join(System.tmp_dir!(), "ixpipe-script-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      limit = config["row_limit"] || 100_000
      total = Table.count(t)
      ext = if parquet?, do: "parquet", else: "jsonl"
      input = Path.join(dir, "in.#{ext}")
      output = Path.join(dir, "out.#{ext}")
      copy = if parquet?, do: "FORMAT parquet", else: "FORMAT json"

      Table.exec!(
        ctx.db,
        "COPY (SELECT * FROM #{Table.ref(t)} LIMIT #{limit}) TO #{literal(input)} (#{copy})"
      )

      warnings =
        if total > limit,
          do: [
            "in: the script got the first #{limit} of #{total} rows. Raise the row limit to pass them all."
          ],
          else: []

      opts = [
        interpreter: config["interpreter"],
        format: if(parquet?, do: "parquet", else: "jsonl"),
        timeout: (config["time_limit"] || @time_limit) * 1000
      ]

      case Script.run(language, code, %{"in" => input}, output, opts) do
        {:ok, %{written: written, stdout: stdout, stderr: stderr}} ->
          %{"out" => read(ctx, output, written), "log" => Code.log(ctx, warnings, stdout, stderr)}

        {:error, %{kind: :exception, message: message, traceback: traceback}} ->
          raise "#{message} Fix the script and run again.\n\n#{String.trim_trailing(traceback)}"

        {:error, %{message: message}} ->
          raise message
      end
    after
      File.rm_rf(dir)
    end
  end

  defp read(ctx, path, %{"format" => "parquet"}),
    do: Context.sql(ctx, "out", "SELECT * FROM read_parquet(#{literal(path)})")

  defp read(ctx, _path, %{"rows" => 0, "columns" => columns}),
    do: Code.output(ctx, columns, [])

  defp read(ctx, path, %{"format" => "jsonl"}),
    do:
      Context.sql(
        ctx,
        "out",
        "SELECT * FROM read_json(#{literal(path)}, format = 'newline_delimited')"
      )
end
