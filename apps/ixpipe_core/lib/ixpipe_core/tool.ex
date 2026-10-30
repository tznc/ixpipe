defmodule IxpipeCore.Tool do
  @moduledoc """
  A workflow tool. `inputs/0` lists its input ports in the order `run/2`
  receives them; a tool with no ports is a source.
  """

  alias Explorer.DataFrame

  @callback inputs() :: [String.t()]
  @doc "Config keys `run/2` cannot do without."
  @callback required_config() :: [String.t()]
  @callback run(%{String.t() => DataFrame.t()}, config :: map()) :: DataFrame.t()
end
