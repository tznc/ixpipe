defmodule IxpipeCore.Tools.Regex do
  @moduledoc """
  Regular expressions on `column` (Rust regex syntax), by `mode`:

    * `parse` (default): each capture group becomes a column, named after
      the group, or `<column>_1`, `_2`, ... when unnamed; empty without a match.
    * `match`: adds `<column>_matched`, true where the whole value matches.
    * `replace`: replaces every match with `replacement` (`$1` refers to a group).
  """
  @behaviour IxpipeCore.Tool

  alias Explorer.{DataFrame, Series}

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "column", label: "Column", type: :string, hint: "The text column to search"},
      %{
        key: "pattern",
        label: "Pattern",
        type: :string,
        hint: "e.g. (?<user>[^@]+)@(?<domain>.+)"
      },
      %{
        key: "mode",
        label: "Mode",
        type: :choice,
        options: ~w(parse match replace),
        default: "parse",
        optional: true
      },
      %{
        key: "replacement",
        label: "Replace with",
        type: :string,
        hint: "For replace; $1 is the first group",
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => df}, %{"column" => column, "pattern" => pattern} = config) do
    series = df[column]

    try do
      case config["mode"] do
        "match" ->
          DataFrame.put(df, "#{column}_matched", matched(series, pattern))

        "replace" ->
          DataFrame.put(
            df,
            column,
            Series.re_replace(series, pattern, config["replacement"] || "")
          )

        _ ->
          parse(df, column, series, pattern)
      end
    rescue
      e in [RuntimeError, ArgumentError] ->
        raise "Invalid pattern #{pattern}: #{Exception.message(e)}"
    end
  end

  defp matched(series, pattern) do
    series
    |> Series.re_contains("^(?:#{pattern})$")
    |> Series.fill_missing(false)
  end

  defp parse(df, column, series, pattern) do
    captures = Series.re_named_captures(series, pattern)
    # The struct holds the whole match ("0") and each group by name or number.
    {:struct, fields} = Series.dtype(captures)

    names =
      for {name, _} <- fields, name != "0", into: %{} do
        {name, if(String.match?(name, ~r/^\d+$/), do: "#{column}_#{name}", else: name)}
      end

    df
    |> DataFrame.put("__captures", captures)
    |> DataFrame.unnest("__captures")
    |> DataFrame.discard(["0"] -- (DataFrame.names(df) -- ["0"]))
    |> DataFrame.rename(names)
  end
end
