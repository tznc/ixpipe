defmodule IxpipeCore.Tools.InputPostgres do
  @moduledoc """
  Reads from PostgreSQL through a saved `connection` (see
  `IxpipeCore.Connections`): a `query`, or every row of a `table`. Numerics
  become floats, timestamps naive UTC, UUIDs and JSON text.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Connections, Database}

  @impl true
  def inputs, do: []

  @impl true
  def fields,
    do: [
      %{
        key: "connection",
        label: "Connection",
        type: :string,
        hint: "A saved Postgres connection"
      },
      %{
        key: "query",
        label: "Query",
        type: :expr,
        optional: true,
        hint: "SQL, e.g. SELECT * FROM orders"
      },
      %{
        key: "table",
        label: "Table",
        type: :string,
        optional: true,
        hint: "Or read a whole table"
      }
    ]

  @impl true
  def run(_inputs, config, ctx) do
    conn = Database.connection!(config, "postgres") || raise "Choose a saved connection"
    sql = Database.sql!(config)

    password =
      case Connections.password(conn) do
        {:ok, password} -> password
        {:error, message} -> raise message
      end

    {:ok, pid} =
      Postgrex.start_link(
        hostname: conn["host"],
        port: conn["port"] || 5432,
        database: conn["database"],
        username: conn["username"],
        password: password,
        backoff_type: :stop,
        max_restarts: 0,
        show_sensitive_data_on_connection_error: false
      )

    try do
      case Postgrex.query(pid, sql, []) do
        {:ok, %Postgrex.Result{columns: columns, rows: rows}} ->
          Database.table(ctx, columns || [], rows || [], uuids: true)

        {:error, %Postgrex.Error{} = error} ->
          raise "Postgres: #{Exception.message(error)}"

        {:error, error} ->
          raise "Postgres: #{inspect(error)}"
      end
    after
      GenServer.stop(pid)
    end
  end
end
