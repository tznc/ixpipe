defmodule IxpipeCore.Tools.TextToColumns do
  @moduledoc """
  Splits `column` on `delimiter`, into new columns `<column>_1`, `_2`, ...
  (`split_to: columns`, the default) or into rows (`split_to: rows`).
  `columns` caps the new columns, keeping the rest in the last one; without
  it there are as many as the most parts.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1, literal: 1]

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "column", label: "Column", type: :string, hint: "The text column to split"},
      %{key: "delimiter", label: "Delimiter", type: :string, hint: "e.g. , or a space"},
      %{
        key: "split_to",
        label: "Split to",
        type: :choice,
        options: ~w(columns rows),
        default: "columns",
        optional: true
      },
      %{
        key: "columns",
        label: "Number of columns",
        type: :integer,
        hint: "Leave empty for as many as needed",
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => t}, %{"column" => column, "delimiter" => delimiter} = config, ctx) do
    parts = "string_split(#{ident(column)}, #{literal(delimiter)})"

    case config["split_to"] do
      "rows" ->
        # A null keeps its row, as one null part.
        Context.sql(
          ctx,
          "SELECT * REPLACE (unnest(coalesce(#{parts}, [NULL])) AS #{ident(column)}) FROM #{Table.ref(t)}"
        )

      _ ->
        to_columns(t, column, delimiter, parts, config["columns"], ctx)
    end
  end

  defp to_columns(t, column, delimiter, parts, limit, ctx) do
    n = limit || most_parts(t, parts)

    new =
      for i <- 1..n//1 do
        part =
          if i == limit,
            do:
              "CASE WHEN len(#{parts}) >= #{i} THEN array_to_string(list_slice(#{parts}, #{i}, len(#{parts})), #{literal(delimiter)}) END",
            else: "#{parts}[#{i}]"

        "#{part} AS #{ident("#{column}_#{i}")}"
      end

    Context.sql(ctx, "SELECT #{Enum.join(["*" | new], ", ")} FROM #{Table.ref(t)}")
  end

  defp most_parts(t, parts) do
    %{rows: [[n]]} =
      Table.query!(t.db, "SELECT coalesce(max(len(#{parts})), 0) FROM #{Table.ref(t)}")

    n
  end
end
