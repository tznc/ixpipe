defmodule IxpipeCore.Run do
  @moduledoc """
  What `IxpipeCore.execute/2` returns. `status` is `:ok` when every node
  ran, `:failed` when one failed. `nodes` holds each node's status: `:ok`,
  `:failed`, or `:skipped` when a node upstream of it failed. `tables` holds
  the tables of every node that ran (keyed as `IxpipeCore.run/2` keys them),
  so a partial run's results stay readable. `messages` are in workflow
  order, each node's most serious first. `ms` is the run's wall time.
  """

  alias IxpipeCore.{Message, Table}

  defstruct status: :ok, nodes: %{}, tables: %{}, messages: [], ms: 0

  @type node_status :: :ok | :failed | :skipped
  @type t :: %__MODULE__{
          status: :ok | :failed,
          nodes: %{String.t() => node_status()},
          tables: %{String.t() => Table.t()},
          messages: [Message.t()],
          ms: non_neg_integer()
        }

  @doc "The run's messages of `level`."
  @spec messages(t(), Message.level()) :: [Message.t()]
  def messages(%__MODULE__{messages: messages}, level),
    do: Enum.filter(messages, &(&1.level == level))

  @doc "The ids of the nodes that failed, in workflow order."
  @spec failed(t()) :: [String.t()]
  def failed(%__MODULE__{} = run),
    do: run |> messages(:error) |> Enum.map(& &1.node) |> Enum.uniq()
end
