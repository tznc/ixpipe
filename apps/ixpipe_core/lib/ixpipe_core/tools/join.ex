defmodule IxpipeCore.Tools.Join do
  @moduledoc """
  Joins `left` and `right` on key columns. Config: `on`, optional `how`
  (`inner` (default), `left`, `outer`, `cross`).
  """
  @behaviour IxpipeCore.Tool

  @how %{"inner" => :inner, "left" => :left, "outer" => :outer, "cross" => :cross}

  @impl true
  def inputs, do: ["left", "right"]

  @impl true
  def required_config, do: ["on"]

  @impl true
  def run(%{"left" => left, "right" => right}, %{"on" => on} = config) do
    how = Map.fetch!(@how, config["how"] || "inner")
    Explorer.DataFrame.join(left, right, on: on, how: how)
  end
end
