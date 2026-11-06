defmodule IxpipeCore.Tools.MultiRowFormula do
  @moduledoc """
  Computes (or updates) column `as` from a DuckDB SQL expression `expr` that
  can read other rows, as Alteryx's Multi-Row Formula does.

  - `[Row-1:amount]` is the previous row's `amount` and `[Row+1:amount]` the
    next one's (any offset; `[Row-0:amount]` is this row's). They compile to
    `lag("amount", 1) OVER w` and `lead("amount", 1) OVER w`.
  - `w` is a named window over the rows in their input order, partitioned by
    `group_by` when given, so any window function works too:
    `sum(amount) OVER w` is a running total.
  - Rows before the first or after the last (`out_of_range`) are NULL, or
    `zero`: 0 for numbers and empty text for text.

  References read the input's values, not values this tool computed. The
  output keeps the input's row order.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @row "__ixpipe_row"
  @ref ~r/\[Row([+-])(\d+):([^\]]+)\]/i

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{
        key: "as",
        label: "Column",
        type: :string,
        hint: "A new column, or an existing one to update"
      },
      %{
        key: "expr",
        label: "Expression",
        type: :expr,
        hint:
          "[Row-1:amount] is the previous row's amount, [Row+1:amount] the next; OVER w windows over the group"
      },
      %{
        key: "group_by",
        label: "Group by",
        type: :list,
        hint: "Rows restart for each group; leave empty for one group",
        optional: true
      },
      %{
        key: "out_of_range",
        label: "Rows out of range",
        type: :choice,
        options: ~w(null zero),
        default: "null",
        hint: "zero is 0 for numbers and empty text for text",
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => t}, %{"as" => as, "expr" => expr} = config, ctx) do
    types = Table.dtypes(t)
    for c <- config["group_by"] || [], !Map.has_key?(types, c), do: raise(missing(c))

    defaults =
      if config["out_of_range"] == "zero",
        do: Map.new(types, fn {c, type} -> {c, zero(type)} end),
        else: %{}

    expr = translate(expr, defaults, types)
    column = "(#{expr}) AS #{ident(as)}"
    select = if Map.has_key?(types, as), do: "* REPLACE (#{column})", else: "*, #{column}"

    partition =
      case config["group_by"] do
        groups when groups not in [nil, []] ->
          "PARTITION BY " <> Enum.map_join(groups, ", ", &ident/1) <> " "

        _ ->
          ""
      end

    # rowid is the input's row order; the input is also the table `df`.
    Context.sql(ctx, """
    WITH df AS (SELECT * FROM #{Table.ref(t)})
    SELECT * EXCLUDE (#{@row}) FROM (
      SELECT #{select} FROM (SELECT *, rowid AS #{@row} FROM #{Table.ref(t)})
      WINDOW w AS (#{partition}ORDER BY #{@row})
    ) ORDER BY #{@row}
    """)
  end

  @doc """
  `expr` with each `[Row±n:column]` as a `lag`/`lead` over the window `w`,
  falling back to `defaults[column]` (SQL) out of range. With `types`, a
  reference to a column not in it raises.
  """
  @spec translate(String.t(), %{String.t() => String.t()}, map() | nil) :: String.t()
  def translate(expr, defaults, types \\ nil) do
    Regex.replace(@ref, expr, fn ref, sign, n, column ->
      if types && !Map.has_key?(types, column), do: raise(missing(column, " in #{ref}"))
      default = if d = defaults[column], do: ", #{d}", else: ""

      case {sign, String.to_integer(n)} do
        {_, 0} -> ident(column)
        {"-", n} -> "lag(#{ident(column)}, #{n}#{default}) OVER w"
        {"+", n} -> "lead(#{ident(column)}, #{n}#{default}) OVER w"
      end
    end)
  end

  defp missing(column, where \\ ""),
    do: ~s(Column "#{column}"#{where} isn't in the input. Check its spelling.)

  defp zero("VARCHAR"), do: "''"

  defp zero(type) do
    if type in ~w(TINYINT SMALLINT INTEGER BIGINT HUGEINT UTINYINT USMALLINT UINTEGER UBIGINT UHUGEINT FLOAT DOUBLE) or
         String.starts_with?(type, "DECIMAL"),
       do: "0"
  end
end
