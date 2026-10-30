defmodule IxpipeCore.Tool do
  @moduledoc """
  A workflow tool. `inputs/0` lists its input ports in the order `run/2`
  receives them; a tool with no ports is a source.
  """

  alias Explorer.DataFrame

  @typedoc """
  A setting, as an editor shows it: `key` in the node's config, a sentence-case
  `label`, a `type` (see `IxpipeCore.Config`), an optional `hint`, `options`
  for a `:choice`, and `optional: true` when `run/2` can do without it.
  """
  @type field :: %{
          required(:key) => String.t(),
          required(:label) => String.t(),
          required(:type) => IxpipeCore.Config.type(),
          optional(:hint) => String.t(),
          optional(:options) => [String.t()],
          optional(:optional) => boolean()
        }

  @callback inputs() :: [String.t()]
  @doc "The tool's settings, in the order an editor shows them."
  @callback fields() :: [field()]
  @callback run(%{String.t() => DataFrame.t()}, config :: map()) :: DataFrame.t()
end
