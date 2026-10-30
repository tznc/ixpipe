defmodule IxpipeCore.Tools.TextToColumns do
  @moduledoc """
  Splits `column` on `delimiter`, into new columns `<column>_1`, `_2`, ...
  (`split_to: columns`, the default) or into rows (`split_to: rows`).
  `columns` caps the new columns, keeping the rest in the last one; without
  it there are as many as the most parts.
  """
  @behaviour IxpipeCore.Tool

  alias Explorer.{DataFrame, Series}

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
  def run(%{"in" => df}, %{"column" => column, "delimiter" => delimiter} = config) do
    case config["split_to"] do
      "rows" ->
        df
        |> DataFrame.put(column, Series.split(df[column], delimiter))
        |> DataFrame.explode(column)

      _ ->
        to_columns(df, column, delimiter, config["columns"])
    end
  end

  defp to_columns(df, column, delimiter, limit) do
    parts =
      for value <- Series.to_list(df[column]) do
        if value, do: String.split(value, delimiter, parts: limit || :infinity), else: []
      end

    n = limit || parts |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    Enum.reduce(1..n//1, df, fn i, df ->
      values = Enum.map(parts, &Enum.at(&1, i - 1))
      DataFrame.put(df, "#{column}_#{i}", Series.from_list(values, dtype: :string))
    end)
  end
end
