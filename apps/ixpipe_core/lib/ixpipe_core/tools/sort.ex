defmodule IxpipeCore.Tools.Sort do
  @moduledoc "Sorts by the listed columns. Config: `by`, optional `desc` (default false)."
  @behaviour IxpipeCore.Tool

  @impl true
  def inputs, do: ["in"]

  @impl true
  def run(%{"in" => df}, %{"by" => by} = config) do
    dir = if config["desc"], do: :desc, else: :asc
    Explorer.DataFrame.sort_with(df, fn ldf -> Enum.map(by, &{dir, ldf[&1]}) end)
  end
end
