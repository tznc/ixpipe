defmodule IxpipeCore.Context do
  @moduledoc """
  What a tool's `run/3` works in: the run's DuckDB database and the node's
  id, which names the tables the node makes (`id`, or `id.output` for each
  output of a tool with several).
  """
  alias IxpipeCore.{Duck, Table}

  @enforce_keys [:db, :id]
  defstruct [:db, :id]

  @type t :: %__MODULE__{db: Duck.db(), id: String.t()}

  @doc "A context in a fresh database, for running a tool on its own (tests)."
  @spec new(String.t()) :: t()
  def new(id \\ "node") do
    {:ok, db} = Duck.open()
    %__MODULE__{db: db, id: id}
  end

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
