defmodule IxpipeCore.Tools.MacroOutput do
  @moduledoc """
  An output port of a macro (see `IxpipeCore.Macro`): `name` (the node's id
  when unset). It passes its input through.
  """
  @behaviour IxpipeCore.Tool

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{
        key: "name",
        label: "Port name",
        type: :string,
        optional: true,
        hint: "Defaults to this tool's id"
      }
    ]

  @impl true
  def run(%{"in" => table}, _config, _ctx), do: table
end
