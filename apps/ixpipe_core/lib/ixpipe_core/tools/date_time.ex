defmodule IxpipeCore.Tools.DateTime do
  @moduledoc """
  Converts `column` between text and dates, as Alteryx's DateTime tool does.
  `convert` `parse` (the default) reads text in `format` into a DATE, or a
  TIMESTAMP when the format has a time; `format` writes a date or time as
  text in `format`. The result is column `as` (default the column's name
  with `_date` or `_text`).

  Formats use Alteryx's (and .NET's) letters, mapped to DuckDB's
  `strptime`/`strftime` by `strftime/1`: `yyyy` `yy` year, `MMMM` `MMM`
  `MM` `M` month, `dddd` `ddd` `dd` `d` day, `HH` `H` 24-hour, `hh` `h`
  12-hour, `mm` `m` minute, `ss` `s` second, `fff` milliseconds, `ffffff`
  microseconds, `tt` AM/PM, `zzz` time zone. A format with `%` in it is
  DuckDB's own and passes through.

  A value that does not parse is NULL in `out`; its rows are also in
  `failed`, and a warning says how many there were.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1, literal: 1]

  @impl true
  def inputs, do: ["in"]

  @impl true
  def outputs, do: ["out", "failed"]

  @impl true
  def fields,
    do: [
      %{key: "column", label: "Column", type: :string},
      %{
        key: "convert",
        label: "Convert",
        type: :choice,
        options: ~w(parse format),
        default: "parse",
        hint: "parse reads text as a date; format writes a date as text",
        optional: true
      },
      %{
        key: "format",
        label: "Format",
        type: :string,
        hint: "e.g. yyyy-MM-dd, dd/MM/yyyy, MM-dd-yyyy HH:mm:ss, d MMM yyyy"
      },
      %{
        key: "as",
        label: "Output column",
        type: :string,
        hint: "Default: the column's name with _date or _text",
        optional: true
      }
    ]

  # Longest first, so `yyyy` is not read as two `yy`.
  @tokens [
    {"yyyy", "%Y"},
    {"yy", "%y"},
    {"MMMM", "%B"},
    {"MMM", "%b"},
    {"MM", "%m"},
    {"M", "%-m"},
    {"dddd", "%A"},
    {"ddd", "%a"},
    {"dd", "%d"},
    {"d", "%-d"},
    {"HH", "%H"},
    {"H", "%-H"},
    {"hh", "%I"},
    {"h", "%-I"},
    {"mm", "%M"},
    {"m", "%-M"},
    {"ss", "%S"},
    {"s", "%-S"},
    {"ffffff", "%f"},
    {"fff", "%g"},
    {"tt", "%p"},
    {"zzz", "%z"}
  ]

  @doc "An Alteryx-style date format as a DuckDB strftime format."
  @spec strftime(String.t()) :: String.t()
  def strftime(format), do: if(duckdb?(format), do: format, else: convert(format, ""))

  # A `%` followed by a letter (or `-` and a letter) is DuckDB's.
  defp duckdb?(format), do: Regex.match?(~r/%-?[a-zA-Z]/, format)

  defp convert("", acc), do: acc
  defp convert("%" <> rest, acc), do: convert(rest, acc <> "%%")

  defp convert(format, acc) do
    case Enum.find(@tokens, fn {token, _} -> String.starts_with?(format, token) end) do
      {token, code} ->
        convert(
          binary_part(format, byte_size(token), byte_size(format) - byte_size(token)),
          acc <> code
        )

      nil ->
        {char, rest} = String.split_at(format, 1)
        convert(rest, acc <> char)
    end
  end

  @impl true
  def run(%{"in" => t}, %{"column" => column, "format" => format} = config, ctx) do
    unless column in Table.columns(t),
      do: raise(~s(Column "#{column}" isn't in the input. Check its spelling.))

    fmt = literal(strftime(format))
    c = ident(column)

    convert = config["convert"] || "parse"

    {result, suffix} =
      case convert do
        "format" ->
          {"strftime(TRY_CAST(#{c} AS TIMESTAMP), #{fmt})", "_text"}

        "parse" ->
          parsed = "try_strptime(CAST(#{c} AS VARCHAR), #{fmt})"
          # No time in the format: a DATE.
          if Regex.match?(~r/%-?[HIMSfgpz]/, strftime(format)),
            do: {parsed, "_date"},
            else: {"CAST(#{parsed} AS DATE)", "_date"}
      end

    as = config["as"] || column <> suffix
    column_sql = "#{result} AS #{ident(as)}"

    select =
      if as in Table.columns(t),
        do: "* REPLACE (#{column_sql})",
        else: "*, #{column_sql}"

    out = Context.sql(ctx, "out", "SELECT #{select} FROM #{Table.ref(t)}")

    failed =
      Context.sql(
        ctx,
        "failed",
        "SELECT * FROM #{Table.ref(t)} WHERE #{c} IS NOT NULL AND (#{result}) IS NULL"
      )

    warn_failed(ctx, failed, column, convert, format)
    %{"out" => out, "failed" => failed}
  end

  defp warn_failed(ctx, failed, column, convert, format) do
    %{rows: [[count, example]]} =
      Table.query!(
        failed.db,
        "SELECT count(*), CAST(first(#{ident(column)}) AS VARCHAR) FROM #{Table.ref(failed)}"
      )

    if count > 0 do
      {values, are} = if count == 1, do: {"1 value", "is"}, else: {"#{count} values", "are"}

      what =
        if convert == "format",
          do: "couldn't be read as a date",
          else: "couldn't be parsed as #{format}"

      Context.warn(
        ctx,
        ~s|#{values} of "#{column}" #{what} and #{are} empty ("#{example}"). | <>
          "Check the format matches the column; the failed output has their rows."
      )
    end

    :ok
  end
end
