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
  The ports of `inputs/0` a node may leave unconnected; `run/3` then gets
  no table for them. Tools without it need every port.
  """
  @callback optional_inputs() :: [String.t()]
  @doc """
  The tool's outputs, when it has more than one (Filter's `true` and
  `false`). `run/3` then returns a map of output name to table. Tools
  without it have one output, `out`.
  """
  @callback outputs() :: [String.t()]
  @optional_callbacks outputs: 0, optional_inputs: 0
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
