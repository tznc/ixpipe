defmodule IxpipeCore.Tools.InputBigquery do
  @moduledoc """
  Reads from Google BigQuery through a saved `bigquery` connection: a
  `query` (GoogleSQL), or every row of a `table` (`dataset.table`), billed
  to the connection's `project`. DuckDB's community `bigquery` extension
  runs it; DuckDB downloads the extension the first time (it is not part of
  libduckdb, and has no Android build).

  Credentials: the connection's `service_account_path` (a key file) or
  `access_token_env`, else Google's application default credentials
  (`gcloud auth application-default login`, `GOOGLE_APPLICATION_CREDENTIALS`).
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Cloud, Connections, Context, Database}
  import IxpipeCore.Duck, only: [literal: 1]

  @impl true
  def inputs, do: []

  @impl true
  def fields,
    do: [
      %{
        key: "connection",
        label: "Connection",
        type: :string,
        kinds: ["bigquery"],
        hint: "A saved BigQuery connection"
      },
      %{
        key: "query",
        label: "Query",
        type: :expr,
        optional: true,
        hint: "GoogleSQL, e.g. SELECT * FROM sales.orders"
      },
      %{
        key: "table",
        label: "Table",
        type: :string,
        optional: true,
        hint: "Or read a whole table: dataset.table"
      }
    ]

  @impl true
  def run(_inputs, config, ctx) do
    conn =
      Database.connection!(config, "bigquery") || raise "Choose a saved BigQuery connection"

    sql = sql(config)
    Cloud.load_extension!(ctx.db, "bigquery", "community")
    if secret = secret_sql(conn), do: IxpipeCore.Table.exec!(ctx.db, secret)

    try do
      Context.sql(
        ctx,
        "SELECT * FROM bigquery_query(#{literal(conn["project"])}, #{literal(sql)})"
      )
    rescue
      e in RuntimeError ->
        if e.message =~ "Authentication Failed",
          do:
            raise(
              "BigQuery couldn't sign in to project #{conn["project"]}. " <>
                "Set the connection's service_account_path to a key file, or run gcloud auth application-default login."
            ),
          else: reraise("BigQuery: " <> e.message, __STACKTRACE__)
    end
  end

  @doc false
  def sql(%{"query" => query}) when is_binary(query) and query != "", do: query

  def sql(%{"table" => table}) when is_binary(table) and table != "",
    do: "SELECT * FROM `" <> String.replace(table, "`", "") <> "`"

  def sql(_config), do: raise("Write a query or name a table")

  @doc "The secret holding `conn`'s credentials; nil for application default credentials."
  def secret_sql(conn) do
    credential =
      cond do
        token = secret!(conn, "access_token_env") -> "ACCESS_TOKEN #{literal(token)}"
        path = conn["service_account_path"] -> "SERVICE_ACCOUNT_PATH #{literal(path)}"
        true -> nil
      end

    if credential do
      name = "ixpipe_bq_" <> String.replace(conn["project"], ~r/[^A-Za-z0-9]/, "_")

      "CREATE OR REPLACE SECRET #{name} (TYPE bigquery, SCOPE #{literal("bq://" <> conn["project"])}, #{credential})"
    end
  end

  defp secret!(conn, key) do
    case Connections.secret(conn, key) do
      {:ok, value} -> value
      {:error, message} -> raise message
    end
  end
end
