defmodule IxpipeCore.Tools.DataCleansing do
  @moduledoc """
  Tidies `columns` (default: all): trims text (`trim`, default true),
  collapses runs of whitespace to one space (`collapse_whitespace`),
  changes `case` (`upper`, `lower`, `title`), fills nulls with "" or 0
  (`replace_nulls`), and drops rows that are entirely null
  (`remove_null_rows`).
  """
  @behaviour IxpipeCore.Tool

  alias Explorer.{DataFrame, Series}

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
  def run(%{"in" => df}, config) do
    df = if config["remove_null_rows"], do: drop_empty_rows(df), else: df
    columns = config["columns"] || DataFrame.names(df)
    Enum.reduce(columns, df, &DataFrame.put(&2, &1, clean(&2[&1], config)))
  end

  defp drop_empty_rows(df) do
    DataFrame.filter_with(df, fn ldf ->
      df
      |> DataFrame.names()
      |> Enum.map(&Series.is_not_nil(ldf[&1]))
      |> Enum.reduce(&Series.or/2)
    end)
  end

  defp clean(%Series{dtype: :string} = series, config) do
    series
    |> then(&if(Map.get(config, "trim", true), do: Series.strip(&1), else: &1))
    |> then(&if(config["collapse_whitespace"], do: Series.re_replace(&1, "\\s+", " "), else: &1))
    |> change_case(config["case"])
    |> then(&if(config["replace_nulls"], do: Series.fill_missing(&1, ""), else: &1))
  end

  defp clean(series, config) do
    if config["replace_nulls"] && Series.dtype(series) in numeric(),
      do: Series.fill_missing(series, 0),
      else: series
  end

  defp change_case(series, "upper"), do: Series.upcase(series)
  defp change_case(series, "lower"), do: Series.downcase(series)
  defp change_case(series, "title"), do: Series.transform(series, &title/1)
  defp change_case(series, _), do: series

  defp title(nil), do: nil

  defp title(text),
    do:
      Regex.replace(~r/\b(\p{L})(\p{L}*)/u, text, fn _, a, b ->
        String.upcase(a) <> String.downcase(b)
      end)

  defp numeric,
    do: [
      {:s, 8},
      {:s, 16},
      {:s, 32},
      {:s, 64},
      {:u, 8},
      {:u, 16},
      {:u, 32},
      {:u, 64},
      {:f, 32},
      {:f, 64}
    ]
end
