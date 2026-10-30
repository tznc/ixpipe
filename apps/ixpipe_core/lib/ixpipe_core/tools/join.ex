defmodule IxpipeCore.Tools.Join do
  @moduledoc """
  Joins `left` and `right` on key columns. Outputs, as Alteryx's J, L and R:
  `joined` (per `how`), `left` (left rows with no match) and `right` (right
  rows with no match). Config: `on`, optional `how` (`inner` (default),
  `left`, `outer`, `cross`).
  """
  @behaviour IxpipeCore.Tool

  alias Explorer.DataFrame

  @how %{"inner" => :inner, "left" => :left, "outer" => :outer, "cross" => :cross}

  @impl true
  def inputs, do: ["left", "right"]

  @impl true
  def fields,
    do: [
      %{key: "on", label: "Join on", type: :list, hint: "Columns both inputs share"},
      %{
        key: "how",
        label: "Join type",
        type: :choice,
        options: ["inner", "left", "outer", "cross"],
        optional: true
      }
    ]

  @impl true
  def outputs, do: ["joined", "left", "right"]

  @impl true
  def run(%{"left" => left, "right" => right}, %{"on" => on} = config) do
    how = Map.fetch!(@how, config["how"] || "inner")

    %{
      "joined" => DataFrame.join(left, right, on: on, how: how),
      "left" => unmatched(left, right, on),
      "right" => unmatched(right, left, on)
    }
  end

  # Rows of `df` whose keys appear nowhere in `other`.
  @marker "__ixpipe_matched"
  defp unmatched(df, other, on) do
    keys = other |> DataFrame.select(on) |> DataFrame.distinct()
    keys = DataFrame.put(keys, @marker, List.duplicate(true, DataFrame.n_rows(keys)))

    df
    |> DataFrame.join(keys, on: on, how: :left)
    |> DataFrame.filter_with(&Explorer.Series.is_nil(&1[@marker]))
    |> DataFrame.discard(@marker)
  end
end
