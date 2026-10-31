defmodule IxpipeCore.Tools.FindReplace do
  @moduledoc """
  Finds the values of the `lookup` input's `find` column in the `in`
  input's `field`, as Alteryx's Find Replace. `match` is `whole` (the
  field equals the value, default) or `any_part` (the field contains it);
  `case_insensitive` ignores case. Blank and null find values never match.

  `action` is `replace` (default): matched text becomes the lookup's
  `replace` column (the whole field, or each occurrence for `any_part`,
  applying the lookup's rows in order); or `append`: adds the lookup's
  `append` columns from the first matching lookup row (null where none
  matches; a name `in` has gets the suffix `_lookup`). Rows keep their
  order.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @impl true
  def inputs, do: ["in", "lookup"]

  @impl true
  def fields,
    do: [
      %{key: "field", label: "Find within", type: :string, hint: "The column of in to search"},
      %{key: "find", label: "Find value", type: :string, hint: "The column of lookup to find"},
      %{
        key: "match",
        label: "Match",
        type: :choice,
        options: ~w(whole any_part),
        default: "whole",
        optional: true
      },
      %{
        key: "case_insensitive",
        label: "Ignore case",
        type: :bool,
        default: false,
        optional: true
      },
      %{
        key: "action",
        label: "Action",
        type: :choice,
        options: ~w(replace append),
        default: "replace",
        optional: true
      },
      %{
        key: "replace",
        label: "Replace with",
        type: :string,
        hint: "The column of lookup to write",
        optional: true
      },
      %{
        key: "append",
        label: "Append columns",
        type: :list,
        hint: "Columns of lookup to add",
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => t, "lookup" => lookup}, %{"field" => field, "find" => find} = config, ctx) do
    ci = config["case_insensitive"] == true
    any = config["match"] == "any_part"
    f = "CAST(s.#{ident(field)} AS VARCHAR)"
    v = "CAST(l.#{ident(find)} AS VARCHAR)"
    {f_cmp, v_cmp} = if ci, do: {"lower(#{f})", "lower(#{v})"}, else: {f, v}
    on = if any, do: "contains(#{f_cmp}, #{v_cmp})", else: "#{f_cmp} = #{v_cmp}"

    base = """
    WITH s AS (SELECT *, rowid AS __rid FROM #{Table.ref(t)}),
    l AS (SELECT *, rowid AS __lid FROM #{Table.ref(lookup)} WHERE nullif(CAST(#{ident(find)} AS VARCHAR), '') IS NOT NULL),
    m AS (
      SELECT s.__rid, l.*, row_number() OVER (PARTITION BY s.__rid ORDER BY l.__lid) AS __k
      FROM s JOIN l ON #{on}
    )
    """

    case config["action"] || "replace" do
      "append" ->
        append(base, t, config["append"] || [], ctx)

      _ ->
        replace =
          config["replace"] || raise "Replace needs a column. Choose the lookup column to write."

        replace(base, field, find, replace, any, ci, ctx)
    end
  end

  defp append(_base, _t, [], _ctx),
    do: raise("Append needs columns. Choose the lookup columns to add.")

  defp append(base, t, columns, ctx) do
    existing = Table.columns(t)

    added =
      Enum.map_join(columns, ", ", fn c ->
        as = if c in existing, do: c <> "_lookup", else: c
        "m.#{ident(c)} AS #{ident(as)}"
      end)

    Context.sql(ctx, """
    #{base}
    SELECT s.* EXCLUDE (__rid), #{added}
    FROM s LEFT JOIN m ON m.__rid = s.__rid AND m.__k = 1
    ORDER BY s.__rid
    """)
  end

  defp replace(base, field, _find, replace, false, _ci, ctx) do
    Context.sql(ctx, """
    #{base}
    SELECT s.* EXCLUDE (__rid) REPLACE (
      CASE WHEN m.__rid IS NULL THEN s.#{ident(field)} ELSE m.#{ident(replace)} END AS #{ident(field)}
    )
    FROM s LEFT JOIN m ON m.__rid = s.__rid AND m.__k = 1
    ORDER BY s.__rid
    """)
  end

  # Any part: every lookup pair in turn, over the field's text.
  defp replace(base, field, find, replace, true, ci, ctx) do
    step =
      if ci,
        do: "regexp_replace(acc, '(?i)' || regexp_escape(x.f), replace(x.r, '\\', '\\\\'), 'g')",
        else: "replace(acc, x.f, x.r)"

    Context.sql(ctx, """
    #{base},
    pairs AS (
      SELECT coalesce(list({'f': CAST(#{ident(find)} AS VARCHAR), 'r': coalesce(CAST(#{ident(replace)} AS VARCHAR), '')} ORDER BY __lid), []) AS p
      FROM l
    )
    SELECT s.* EXCLUDE (__rid) REPLACE (
      list_reduce(pairs.p, lambda acc, x: #{step}, CAST(s.#{ident(field)} AS VARCHAR)) AS #{ident(field)}
    )
    FROM s CROSS JOIN pairs
    ORDER BY s.__rid
    """)
  end
end
