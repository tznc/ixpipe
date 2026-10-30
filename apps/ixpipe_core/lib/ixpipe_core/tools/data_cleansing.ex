defmodule IxpipeCore.Tools.DataCleansing do
  @moduledoc """
  Tidies `columns` (default: all): trims text (`trim`, default true),
  collapses runs of whitespace to one space (`collapse_whitespace`),
  changes `case` (`upper`, `lower`, `title`), fills nulls with "" or 0
  (`replace_nulls`), and drops rows that are entirely null
  (`remove_null_rows`).
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{
        key: "columns",
        label: "Columns",
        type: :list,
        hint: "Leave empty for every column",
        optional: true
      },
      %{
        key: "remove_null_rows",
        label: "Remove empty rows",
        type: :bool,
        default: false,
        optional: true
      },
      %{
        key: "replace_nulls",
        label: "Replace nulls with blanks and 0",
        type: :bool,
        default: false,
        optional: true
      },
      %{key: "trim", label: "Trim spaces", type: :bool, default: true, optional: true},
      %{
        key: "collapse_whitespace",
        label: "Collapse whitespace",
        type: :bool,
        default: false,
        optional: true
      },
      %{
        key: "case",
        label: "Case",
        type: :choice,
        options: ~w(keep upper lower title),
        default: "keep",
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => t}, config, ctx) do
    types = Table.dtypes(t)
    all = Table.columns(t)
    columns = config["columns"] || all

    cleaned =
      columns
      |> Enum.map(&{clean(ident(&1), types[&1], config), ident(&1)})
      |> Enum.reject(fn {expr, c} -> expr == c end)
      |> Enum.map(fn {expr, c} -> "#{expr} AS #{c}" end)

    select = if cleaned == [], do: "*", else: "* REPLACE (#{Enum.join(cleaned, ", ")})"

    where =
      if config["remove_null_rows"],
        do: " WHERE " <> Enum.map_join(all, " OR ", &"#{ident(&1)} IS NOT NULL"),
        else: ""

    Context.sql(ctx, "SELECT #{select} FROM #{Table.ref(t)}#{where}")
  end

  # Whitespace, as Unicode has it.
  @space ~S"[\s\p{Z}]"

  defp clean(c, "VARCHAR", config) do
    c
    |> then(
      &if Map.get(config, "trim", true),
        do: "regexp_replace(#{&1}, '^#{@space}+|#{@space}+$', '', 'g')",
        else: &1
    )
    |> then(
      &if config["collapse_whitespace"],
        do: "regexp_replace(#{&1}, '#{@space}+', ' ', 'g')",
        else: &1
    )
    |> change_case(config["case"])
    |> then(&if config["replace_nulls"], do: "coalesce(#{&1}, '')", else: &1)
  end

  defp clean(c, type, config) do
    if config["replace_nulls"] && numeric?(type), do: "coalesce(#{c}, 0)", else: c
  end

  defp change_case(c, "upper"), do: "upper(#{c})"
  defp change_case(c, "lower"), do: "lower(#{c})"

  # Each run of letters after a non-word character (or at the start) gets a
  # capital and lower case after it: split into (non-letters)(letters)
  # tokens and capitalise the tokens whose non-letters end in one.
  defp change_case(c, "title") do
    """
    array_to_string(list_transform(regexp_extract_all(#{c}, '\\P{L}*\\p{L}*'), lambda tok:
      CASE WHEN regexp_matches(tok, '^(\\P{L}*[^\\p{L}\\p{N}\\p{M}_])?\\p{L}')
        THEN regexp_extract(tok, '^\\P{L}*') || upper(regexp_extract(tok, '\\p{L}')) ||
          lower(regexp_extract(tok, '^\\P{L}*\\p{L}(.*)', 1))
        ELSE tok END), '')
    """
  end

  defp change_case(c, _), do: c

  defp numeric?(type),
    do:
      type in ~w(TINYINT SMALLINT INTEGER BIGINT HUGEINT UTINYINT USMALLINT UINTEGER UBIGINT UHUGEINT FLOAT DOUBLE) or
        String.starts_with?(type, "DECIMAL")
end
