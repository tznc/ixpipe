defmodule IxpipeCore.Tool do
  @moduledoc """
  A workflow tool. `inputs/0` lists its input ports in the order `run/2`
  receives them; a tool with no ports is a source.
  """

  alias Explorer.DataFrame

  @typedoc """
  A setting, as an editor shows it: `key` in the node's config, a sentence-case
  `label`, a `type` (see `IxpipeCore.Config`), an optional `hint`, `options`
  for a `:choice`, and `optional: true` when `run/2` can do without it. A
  `:path` may list the file extensions it `accept`s, and `save: true` when
  the tool writes the file (an editor then offers a save dialog). `default`
  is what `run/2` assumes when an optional setting is absent.
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
  `false`). `run/2` then returns a map of output name to frame. Tools
  without it have one output, `out`.
  """
  @callback outputs() :: [String.t()]
  @optional_callbacks outputs: 0
  @doc "The tool's settings, in the order an editor shows them."
  @callback fields() :: [field()]
  @callback run(%{String.t() => DataFrame.t()}, config :: map()) ::
              DataFrame.t() | %{String.t() => DataFrame.t()}
end
