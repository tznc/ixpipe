defmodule IxpipeCore.Tools.MultiFieldFormula do
  @moduledoc """
  Applies one DuckDB SQL expression to many columns, as Alteryx's Multi-Field
  Formula does. In `expr`, `_current_` (or Alteryx's `[_CurrentField_]`) is
  the column being computed and `_current_name_` its name as text.

  `columns` lists the columns; left empty, it is every column of `types`
  (`all`, `text`, `numeric` or `date`). `mode` `replace` (the default)
  updates each column in place; `add` adds a column each, named with
  `prefix` and `suffix` (default suffix `_new`).
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1, literal: 1]

  @numeric ~w(TINYINT SMALLINT INTEGER BIGINT HUGEINT UTINYINT USMALLINT UINTEGER UBIGINT UHUGEINT FLOAT DOUBLE)

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{
        key: "columns",
        label: "Columns",
        type: :list,
        hint: "Leave empty for every column of the type below",
        optional: true
      },
      %{
        key: "types",
        label: "Column types",
        type: :choice,
        options: ~w(all text numeric date),
        default: "all",
        optional: true
      },
      %{
        key: "expr",
        label: "Expression",
        type: :expr,
        hint: "_current_ is each column, e.g. upper(trim(_current_))"
      },
      %{
        key: "mode",
        label: "Output",
        type: :choice,
        options: ~w(replace add),
        default: "replace",
        hint: "replace updates each column; add adds a column each",
        optional: true
      },
      %{key: "prefix", label: "New column prefix", type: :string, optional: true},
      %{
        key: "suffix",
        label: "New column suffix",
        type: :string,
        hint: "Default _new, when neither is set",
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => t}, %{"expr" => expr} = config, ctx) do
    types = Table.dtypes(t)

    columns =
      case config["columns"] do
        columns when columns not in [nil, []] ->
          for c <- columns, !Map.has_key?(types, c) do
            raise "#{c} is not a column of the input. Check its spelling."
          end

          columns

        _ ->
          for c <- Table.columns(t), kind?(types[c], config["types"] || "all"), do: c
      end

    exprs = for c <- columns, do: {c, "(#{current(expr, c)})"}

    select =
      cond do
        exprs == [] ->
          "*"

        config["mode"] == "add" ->
          {prefix, suffix} =
            case {config["prefix"], config["suffix"]} do
              {nil, nil} -> {"", "_new"}
              {prefix, suffix} -> {prefix || "", suffix || ""}
            end

          "*, " <>
            Enum.map_join(exprs, ", ", fn {c, e} -> "#{e} AS #{ident(prefix <> c <> suffix)}" end)

        true ->
          "* REPLACE (" <>
            Enum.map_join(exprs, ", ", fn {c, e} -> "#{e} AS #{ident(c)}" end) <> ")"
      end

    # The input is also the table `df`, for subqueries.
    Context.sql(ctx, "WITH df AS (SELECT * FROM #{Table.ref(t)}) SELECT #{select} FROM df")
  end

  defp current(expr, column) do
    expr
    |> then(&Regex.replace(~r/_current_name_/i, &1, fn _ -> literal(column) end))
    |> then(&Regex.replace(~r/\[_CurrentField_\]|_current_/i, &1, fn _ -> ident(column) end))
  end

  defp kind?(_type, "all"), do: true
  defp kind?(type, "text"), do: type == "VARCHAR"
  defp kind?(type, "numeric"), do: type in @numeric or String.starts_with?(type, "DECIMAL")
  defp kind?(type, "date"), do: type in ~w(DATE TIME) or String.starts_with?(type, "TIMESTAMP")
end
