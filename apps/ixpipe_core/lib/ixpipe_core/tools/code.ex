defmodule IxpipeCore.Tools.Code do
  @moduledoc """
  What the code tools (`Python`, `Script`) share: the rows they hand a
  script, at most `row_limit`; the table a script's rows become; and the
  `log` output, a row per line of stdout, stderr and warnings.
  """
  alias IxpipeCore.{Context, Table}

  @row_limit 100_000

  @doc "The row limit field, and its default."
  def row_limit_field,
    do: %{
      key: "row_limit",
      label: "Row limit",
      type: :integer,
      optional: true,
      default: @row_limit,
      hint: "Rows passed to the script from each input; the rest are cut, with a warning"
    }

  @doc "`{columns, rows}` of `table`, at most `limit` rows, and a warning when cut."
  @spec cut(Table.t(), pos_integer() | nil, String.t()) ::
          {{[String.t()], [[term()]]}, [String.t()]}
  def cut(table, limit, port) do
    limit = limit || @row_limit
    total = Table.count(table)

    warnings =
      if total > limit,
        do: [
          "#{port}: the script got the first #{limit} of #{total} rows. " <>
            "Raise the row limit to pass them all."
        ],
        else: []

    {Table.values(table, limit), warnings}
  end

  @doc """
  The node's `out` table from a script's columns and rows. A column mixing
  integers and floats is floats; mixing anything else, text.
  """
  @spec output(Context.t(), [String.t()], [[term()]]) :: Table.t()
  def output(ctx, [], _rows), do: Context.sql(ctx, "out", "SELECT NULL::VARCHAR AS empty LIMIT 0")

  def output(ctx, columns, rows) do
    values = if rows == [], do: Enum.map(columns, fn _ -> [] end), else: Enum.zip_with(rows, & &1)
    Context.table(ctx, "out", Enum.zip(columns, Enum.map(values, &uniform/1)))
  end

  defp uniform(values) do
    kinds = values |> Enum.reject(&is_nil/1) |> Enum.map(&kind/1) |> Enum.uniq()

    case kinds do
      [_] ->
        values

      [] ->
        values

      k ->
        if Enum.sort(k) == [:float, :integer],
          do: Enum.map(values, &float/1),
          else: Enum.map(values, &text/1)
    end
  end

  defp kind(v) when is_integer(v), do: :integer
  defp kind(v) when is_float(v), do: :float
  defp kind(%module{}), do: module
  defp kind(v) when is_boolean(v), do: :boolean
  defp kind(_), do: :text

  defp float(nil), do: nil
  defp float(v), do: v / 1

  defp text(nil), do: nil
  defp text(v) when is_binary(v), do: v
  defp text(v), do: to_string(v)

  @doc "The node's `log` table: `stream` (warning, stdout, stderr) and `line`."
  @spec log(Context.t(), [String.t()], String.t(), String.t()) :: Table.t()
  def log(ctx, warnings, stdout, stderr \\ "") do
    lines =
      Enum.map(warnings, &{"warning", &1}) ++ lines("stdout", stdout) ++ lines("stderr", stderr)

    Context.table(ctx, "log",
      stream: Enum.map(lines, &elem(&1, 0)),
      line: Enum.map(lines, &elem(&1, 1))
    )
  end

  defp lines(stream, text) do
    text
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&{stream, &1})
  end
end
