defmodule IxpipeCore.Context do
  @moduledoc """
  What a tool's `run/3` works in: the run's DuckDB database, the node's
  id, which names the tables the node makes (`id`, or `id.output` for each
  output of a tool with several), and the run's message log, where
  `warn/2` and `info/2` record messages for the node.

  The log is an ETS table shared by the run's nodes: Runic steps run
  concurrently, and each insert is atomic. Without a log (`log: nil`),
  messages are dropped.
  """
  alias IxpipeCore.{Duck, Message, Table}

  @enforce_keys [:db, :id]
  defstruct [:db, :id, log: nil]

  @type log :: :ets.tid() | nil
  @type t :: %__MODULE__{db: Duck.db(), id: String.t(), log: log()}

  @doc "A context in a fresh database, for running a tool on its own (tests)."
  @spec new(String.t()) :: t()
  def new(id \\ "node") do
    {:ok, db} = Duck.open()
    %__MODULE__{db: db, id: id, log: new_log()}
  end

  @doc false
  # Owned by the calling process: a run deletes it when done.
  @spec new_log() :: :ets.tid()
  def new_log, do: :ets.new(__MODULE__, [:ordered_set, :public, write_concurrency: true])

  @doc "Records a warning for the node: it ran, but its user should check this."
  @spec warn(t(), String.t()) :: :ok
  def warn(ctx, text), do: record(ctx, :warning, text)

  @doc "Records information for the node, such as a file it wrote."
  @spec info(t(), String.t()) :: :ok
  def info(ctx, text), do: record(ctx, :info, text)

  @doc false
  @spec record(t(), Message.level(), String.t(), String.t() | nil) :: :ok
  def record(ctx, level, text, detail \\ nil)
  def record(%__MODULE__{log: nil}, _level, _text, _detail), do: :ok

  def record(%__MODULE__{log: log, id: id}, level, text, detail) do
    message = %Message{node: id, level: level, text: text, detail: detail}
    :ets.insert(log, {:erlang.unique_integer([:monotonic]), message})
    :ok
  end

  @doc "The messages recorded in the context's log, oldest first."
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{log: nil}), do: []
  def messages(%__MODULE__{log: log}), do: log |> :ets.tab2list() |> Enum.map(&elem(&1, 1))

  @doc "The node's table for `output` (its only output when nil)."
  @spec name(t(), String.t() | nil) :: String.t()
  def name(%__MODULE__{id: id}, nil), do: id
  def name(%__MODULE__{id: id}, output), do: "#{id}.#{output}"

  @doc "Keeps `select` as the node's table for `output`."
  @spec sql(t(), String.t() | nil, String.t()) :: Table.t()
  def sql(%__MODULE__{db: db} = ctx, output \\ nil, select),
    do: Table.sql(db, name(ctx, output), select)

  @doc "The node's table for `output`, from Elixir column values (see `Table.new/3`)."
  @spec table(t(), String.t() | nil, [{atom() | String.t(), [term()]}]) :: Table.t()
  def table(%__MODULE__{db: db} = ctx, output \\ nil, columns),
    do: Table.new(db, name(ctx, output), columns)
end
