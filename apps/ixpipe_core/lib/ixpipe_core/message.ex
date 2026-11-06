defmodule IxpipeCore.Message do
  @moduledoc """
  A message a run reports about one node: `:info` (rows and time, files
  written), `:warning` (the node ran, but check this) or `:error` (it
  failed). `text` reads "what happened. what to do."; `detail` keeps the raw
  error, when there is one.
  """

  @enforce_keys [:node, :level, :text]
  defstruct [:node, :level, :text, detail: nil]

  @type level :: :info | :warning | :error
  @type t :: %__MODULE__{
          node: String.t(),
          level: level(),
          text: String.t(),
          detail: String.t() | nil
        }

  @doc "Orders levels most serious first."
  @spec rank(level()) :: 0..2
  def rank(:error), do: 0
  def rank(:warning), do: 1
  def rank(:info), do: 2
end
