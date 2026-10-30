defmodule IxpipeCore.Duck do
  @moduledoc """
  DuckDB (spike), through a Rust NIF (`native/ixpipe_duckdb`) with DuckDB
  bundled. Results come back as Arrow IPC and load into Explorer.
  """
  use Rustler, otp_app: :ixpipe_core, crate: "ixpipe_duckdb", mode: :release

  alias Explorer.DataFrame

  @doc "Runs `sql` in a fresh in-memory database with `settings` (`SET key = value`)."
  @spec frame(String.t(), [{String.t(), String.t()}]) ::
          {:ok, DataFrame.t()} | {:error, String.t()}
  def frame(sql, settings \\ []) do
    with {:ok, ipc} <- query(sql, settings), do: DataFrame.load_ipc_stream(ipc)
  end

  @doc false
  def query(_sql, _settings), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Quotes `name` as an SQL identifier."
  def ident(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  @doc "Quotes `text` as an SQL string."
  def literal(text), do: "'" <> String.replace(text, "'", "''") <> "'"
end
