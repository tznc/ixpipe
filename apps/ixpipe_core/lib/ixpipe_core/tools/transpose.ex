defmodule IxpipeCore.Tools.Transpose do
  @moduledoc """
  Pivots wide data long: each of `columns` (default: every column not in
  `keys`) becomes rows of `name` and `value`, beside the `keys` columns.
  Values of mixed types become text.
  """
  @behaviour IxpipeCore.Tool

  alias Explorer.{DataFrame, Series}

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "keys", label: "Key columns", type: :list, hint: "Columns to keep on every row"},
      %{
        key: "columns",
        label: "Data columns",
        type: :list,
        hint: "Leave empty for every other column",
        optional: true
      }
    ]

  @impl true
  def run(%{"in" => df}, %{"keys" => keys} = config) do
    columns = config["columns"] || DataFrame.names(df) -- keys
    df = DataFrame.select(df, keys ++ columns)

    df =
      case columns |> Enum.map(&Series.dtype(df[&1])) |> Enum.uniq() do
        [_] -> df
        _ -> Enum.reduce(columns, df, &DataFrame.put(&2, &1, Series.cast(&2[&1], :string)))
      end

    DataFrame.pivot_longer(df, columns, select: keys, names_to: "name", values_to: "value")
  end
end
