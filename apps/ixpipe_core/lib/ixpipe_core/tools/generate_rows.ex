defmodule IxpipeCore.Tools.GenerateRows do
  @moduledoc """
  Generates rows as a loop, as Alteryx's Generate Rows: the column `name`
  starts at the `init` expression and steps by the `loop` expression while
  the `condition` expression holds (all DuckDB SQL, seeing `name` and, per
  row, the input's columns).

  Its `in` port is optional: unconnected, the tool is a source of one
  loop's rows; connected, it loops once per input row, each generated row
  keeping that row's columns (and replacing a column called `name`).

  It runs as a recursive CTE, stopping at `max_rows` rows per loop
  (default 100,000): a condition still true there fails the node.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @default_max 100_000

  @impl true
  def inputs, do: ["in"]

  @impl true
  def optional_inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "name", label: "Column name", type: :string, hint: "The column the loop writes"},
      %{key: "init", label: "Initial expression", type: :expr, hint: "e.g. 1"},
      %{key: "condition", label: "Condition expression", type: :expr, hint: "e.g. n <= 10"},
      %{key: "loop", label: "Loop expression", type: :expr, hint: "e.g. n + 1"},
      %{
        key: "max_rows",
        label: "Most rows per loop",
        type: :integer,
        default: @default_max,
        optional: true
      }
    ]

  @impl true
  def run(
        inputs,
        %{"name" => name, "init" => init, "condition" => cond, "loop" => loop} = config,
        ctx
      ) do
    max = config["max_rows"] || @default_max
    unless is_integer(max) and max > 0, do: raise("Most rows per loop must be above 0. Raise it.")

    col = ident(name)

    {source, columns} =
      case inputs do
        %{"in" => t} -> {"SELECT *, rowid AS __rid FROM #{Table.ref(t)}", Table.columns(t)}
        _ -> {"SELECT 0 AS __rid", []}
      end

    start =
      if name in columns,
        do: "SELECT * REPLACE ((#{init}) AS #{col}), 0 AS __iter FROM src",
        else: "SELECT *, (#{init}) AS #{col}, 0 AS __iter FROM src"

    # Rows __iter 0..max-1 are kept; a row at `max` that still meets the
    # condition means the loop had more to give.
    work = "#{ctx.id}.__generate"

    gen =
      Table.sql(ctx.db, work, """
      WITH RECURSIVE src AS (#{source}),
      gen AS (
        #{start}
        UNION ALL
        SELECT * REPLACE ((#{loop}) AS #{col}, __iter + 1 AS __iter)
        FROM gen WHERE (#{cond}) AND __iter < #{max}
      )
      SELECT * FROM gen WHERE (#{cond})
      """)

    try do
      %{rows: [[over]]} =
        Table.query!(ctx.db, "SELECT count(*) FROM #{Table.ref(gen)} WHERE __iter >= #{max}")

      if over > 0,
        do:
          raise(
            "The loop reached #{max} rows and its condition still held. " <>
              "Check the loop expression ends the condition, or raise Most rows per loop."
          )

      Context.sql(
        ctx,
        "SELECT * EXCLUDE (__rid, __iter) FROM #{Table.ref(gen)} ORDER BY __rid, __iter"
      )
    after
      Table.exec!(ctx.db, "DROP TABLE IF EXISTS #{Table.ref(gen)}")
    end
  end
end
