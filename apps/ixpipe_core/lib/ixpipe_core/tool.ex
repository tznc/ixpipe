defmodule IxpipeCore.Tool do
  @moduledoc """
  A workflow tool. `inputs/0` lists its input ports in the order `run/3`
  receives them; a tool with no ports is a source. Tools work on
  `IxpipeCore.Table`s in the run's DuckDB database (`IxpipeCore.Context`).
  """

  alias IxpipeCore.{Context, Table}

  @typedoc """
  A setting, as an editor shows it: `key` in the node's config, a sentence-case
  `label`, a `type` (see `IxpipeCore.Config`), an optional `hint`, `options`
  for a `:choice`, and `optional: true` when `run/3` can do without it. A
  `:path` may list the file extensions it `accept`s, and `save: true` when
  the tool writes the file (an editor then offers a save dialog). `default`
  is what `run/3` assumes when an optional setting is absent.
  """
  @type field :: %{
          required(:key) => String.t(),
          required(:label) => String.t(),
          required(:type) => IxpipeCore.Config.type(),
          optional(:hint) => String.t(),
          optional(:options) => [String.t()],
          optional(:optional) => boolean(),
          optional(:accept) => [String.t()],
          optional(:save) => boolean(),
          optional(:default) => term()
        }

  @callback inputs() :: [String.t()]
  @doc """
  The tool's outputs, when it has more than one (Filter's `true` and
  `false`). `run/3` then returns a map of output name to table. Tools
  without it have one output, `out`.
  """
  @callback outputs() :: [String.t()]
  @doc """
  For a tool whose ports and settings depend on the node (a macro, whose
  declaration is in `node.macro`): the node's inputs, outputs and fields.
  `IxpipeCore.Tools.inputs/1`, `outputs/1` and `fields/1` prefer them.
  """
  @callback inputs(IxpipeCore.Spec.Node.t()) :: [String.t()]
  @callback outputs(IxpipeCore.Spec.Node.t()) :: [String.t()]
  @callback fields(IxpipeCore.Spec.Node.t()) :: [field()]
  @optional_callbacks outputs: 0, inputs: 1, outputs: 1, fields: 1
  @doc "The tool's settings, in the order an editor shows them."
  @callback fields() :: [field()]
  @doc """
  Runs the tool on its input tables, returning its table (or a map of
  output name to table). Make new tables with `Context.sql/3`, named for
  the node; raise with a message to fail the node.
  """
  @callback run(%{String.t() => Table.t()}, config :: map(), Context.t()) ::
              Table.t() | %{String.t() => Table.t()}
end
