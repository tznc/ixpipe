defmodule IxpipeCore.Sqlite do
  @moduledoc """
  SQLite through a Rust NIF (`native/ixpipe_sqlite`): rusqlite with SQLite
  bundled, so it builds from source on every target, Android included.
  Each call opens the database at `path`, works and closes it.
  """
  use Rustler, otp_app: :ixpipe_core, crate: "ixpipe_sqlite"

  @type value :: nil | integer() | float() | binary()

  @doc "Runs one or more statements, creating the database if needed."
  @spec execute(Path.t(), String.t()) :: :ok | {:error, String.t()}
  def execute(_path, _sql), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Runs a read-only query. Rows are lists in column order: nil, integers,
  floats, strings, or binaries for BLOBs.
  """
  @spec query(Path.t(), String.t()) ::
          {:ok, {[String.t()], [[value()]]}} | {:error, String.t()}
  def query(_path, _sql), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  In one transaction, runs each statement in `before`, then `insert` once
  per row of parameters. On any error nothing is kept.
  """
  @spec write(Path.t(), [String.t()], String.t(), [[value()]]) :: :ok | {:error, String.t()}
  def write(_path, _before, _insert, _rows), do: :erlang.nif_error(:nif_not_loaded)
end
