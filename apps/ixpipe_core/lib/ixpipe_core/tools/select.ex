defmodule IxpipeCore.Tools.Select do
  @moduledoc "Keeps the listed columns, in order. Config: `columns`."
  @behaviour IxpipeCore.Tool

  @impl true
  def inputs, do: ["in"]

  @impl true
  def run(%{"in" => df}, %{"columns" => columns}), do: Explorer.DataFrame.select(df, columns)
end
