defmodule IxpipeCore.Tools.Macro do
  @moduledoc """
  A macro used as a tool: config `path`, the macro workflow relative to this
  workflow's folder, then the macro's parameters by name. Its ports and
  settings come from the macro's declaration (`node.macro`, see
  `IxpipeCore.Macro`).
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.Macro

  @path %{
    key: "path",
    label: "Macro",
    type: :path,
    accept: ["yaml"],
    hint: "A macro workflow, relative to this workflow's folder"
  }

  @impl true
  def inputs, do: []

  @impl true
  def fields, do: [@path]

  @impl true
  def inputs(%{macro: %Macro{} = macro}), do: Macro.inputs(macro)
  def inputs(_node), do: []

  @impl true
  def outputs(%{macro: %Macro{} = macro}), do: Macro.outputs(macro)
  def outputs(_node), do: ["out"]

  @impl true
  def fields(%{macro: %Macro{} = macro}), do: [@path | Macro.fields(macro)]
  def fields(_node), do: [@path]

  @impl true
  def run(inputs, %{"_macro" => %Macro{} = macro} = config, ctx),
    do: Macro.run(macro, inputs, config, ctx)
end
