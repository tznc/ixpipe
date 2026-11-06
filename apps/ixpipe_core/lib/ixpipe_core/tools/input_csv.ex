defmodule IxpipeCore.Tools.InputCsv do
  @moduledoc """
  Reads a CSV file. Config: `path`. Rows that fail to parse are skipped
  with a warning naming the first, as is a column of numbers that a few
  values made text.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table, Warnings}
  import IxpipeCore.Duck, only: [ident: 1, literal: 1]

  @impl true
  def inputs, do: []

  @impl true
  def fields,
    do: [
      %{
        key: "path",
        label: "File",
        type: :path,
        accept: ["csv"],
        hint: "A CSV file on this computer"
      }
    ]

  @impl true
  def run(_inputs, %{"path" => path}, ctx) do
    name = Context.name(ctx, nil)
    rejects = name <> ".__rejects"

    # DuckDB keeps rejected rows in a temporary table of the connection that
    # read the file, so copy them out in the same call.
    Table.exec!(ctx.db, """
    CREATE OR REPLACE TABLE #{ident(name)} AS
      SELECT * FROM read_csv(#{literal(path)}, store_rejects = true,
        rejects_table = 'ixpipe_rejects', rejects_scan = 'ixpipe_rejects_scan');
    CREATE OR REPLACE TABLE #{ident(rejects)} AS
      SELECT line, first(error_message ORDER BY byte_position) AS error_message
      FROM ixpipe_rejects GROUP BY line ORDER BY line;
    """)

    %{rows: rows} = Table.query!(ctx.db, "SELECT line, error_message FROM #{ident(rejects)}")
    Table.exec!(ctx.db, "DROP TABLE #{ident(rejects)}")
    table = %Table{db: ctx.db, name: name}

    case rows do
      [] ->
        :ok

      [[line, error] | _] ->
        {count, them, was} =
          if length(rows) == 1,
            do: {"1 row", "it", "was"},
            else: {"#{length(rows)} rows", "them", "were"}

        Context.warn(
          ctx,
          "#{count} couldn't be read and #{was} skipped (line #{line}: #{first_line(error)}). " <>
            "Fix #{them} in the file, or check its delimiter and quoting."
        )
    end

    Warnings.numbers_as_text(ctx, table)
    table
  end

  defp first_line(error),
    do: error |> String.split("\n", trim: true) |> List.first("") |> String.trim_trailing(".")
end
