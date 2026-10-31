defmodule IxpipeCore.Cloud do
  @moduledoc """
  Cloud storage paths for the file tools: S3 (`s3://`, and S3-compatible
  stores through an `endpoint`), Google Cloud Storage (`gs://`) and Azure
  Blob Storage (`az://`, `abfss://`). DuckDB reads and writes them through
  its `httpfs` and `azure` extensions, which are not part of libduckdb:
  DuckDB downloads them from extensions.duckdb.org the first time a run
  needs one, into `~/.duckdb/extensions`.

  A tool's optional `connection` names a saved `s3`, `gcs` or `azure`
  connection (`IxpipeCore.Connections`); `prepare!/3` turns it into a
  DuckDB secret scoped to the path's bucket, for this run's database only.
  Without one, public buckets still read.
  """

  alias IxpipeCore.{Connections, Duck, Table}

  @schemes %{
    "s3" => "s3",
    "s3a" => "s3",
    "s3n" => "s3",
    "r2" => "s3",
    "gs" => "gcs",
    "gcs" => "gcs",
    "az" => "azure",
    "azure" => "azure",
    "abfss" => "azure"
  }
  @extensions %{"s3" => "httpfs", "gcs" => "httpfs", "azure" => "azure", "http" => "httpfs"}

  @doc "The connection kinds the file tools take."
  def kinds, do: ~w(s3 gcs azure)

  @doc "The settings a file tool adds for cloud paths."
  def connection_field,
    do: %{
      key: "connection",
      label: "Cloud connection",
      type: :string,
      kinds: kinds(),
      optional: true,
      hint: "For s3://, gs:// or az:// paths; none for public buckets"
    }

  @doc "The cloud a path is in (`\"s3\"`, `\"gcs\"`, `\"azure\"`, `\"http\"`), or nil for a local path."
  @spec kind(String.t()) :: String.t() | nil
  def kind(path) do
    case Regex.run(~r{^([a-z][a-z0-9]+)://}i, path) do
      [_, scheme] ->
        scheme = String.downcase(scheme)
        if scheme in ~w(http https), do: "http", else: @schemes[scheme]

      nil ->
        nil
    end
  end

  @doc """
  Readies the run's database for `path`: loads the extension its cloud
  needs and makes a secret from the saved connection `config` names.
  Local paths need nothing.
  """
  def prepare!(db, path, config) do
    case kind(path) do
      nil ->
        :ok

      kind ->
        load_extension!(db, @extensions[kind])

        case connection!(config) do
          nil ->
            :ok

          %{"type" => ^kind} = conn ->
            Table.exec!(db, secret_sql(conn, path))

          conn ->
            raise "Connection #{conn["name"]} is #{conn["type"]}, but #{path} needs a #{kind} connection. " <>
                    "Choose one, or no connection for a public bucket."
        end
    end
  end

  defp connection!(%{"connection" => name} = config) when is_binary(name) and name != "" do
    case Connections.get(config["_home"] || Connections.dir(), name) do
      {:ok, conn} -> conn
      {:error, message} -> raise message
    end
  end

  defp connection!(_config), do: nil

  @doc "Loads a DuckDB extension, installing it (from `repository`) first if it must."
  def load_extension!(db, extension, repository \\ nil) do
    from = if repository, do: " FROM #{repository}", else: ""

    with {:error, _} <- Duck.execute(db, "LOAD #{extension}"),
         {:error, message} <- Duck.execute(db, "INSTALL #{extension}#{from}; LOAD #{extension}") do
      raise extension_error(extension, message)
    else
      :ok -> :ok
    end
  end

  @doc "What to say when DuckDB can't load `extension`."
  def extension_error(extension, reason) do
    "Couldn't load DuckDB's #{extension} extension (#{first_line(reason)}). " <>
      "Connect to the internet once so DuckDB can download it, then run again."
  end

  defp first_line(text), do: text |> String.split("\n", trim: true) |> List.first("")

  @doc "The `CREATE SECRET` statement for `conn`, scoped to `path`'s bucket or container."
  def secret_sql(conn, path) do
    scope = scope(path)

    options =
      case conn["type"] do
        type when type in ~w(s3 gcs) ->
          [{"KEY_ID", conn["key_id"]}, {"SECRET", secret!(conn, "secret_env")}] ++
            if type == "s3",
              do: [
                {"REGION", conn["region"]},
                {"SESSION_TOKEN", secret!(conn, "session_token_env")},
                {"ENDPOINT", conn["endpoint"]},
                {"URL_STYLE", conn["url_style"]},
                {"USE_SSL", conn["use_ssl"]}
              ],
              else: []

        "azure" ->
          [{"CONNECTION_STRING", secret!(conn, "connection_string_env")}]
      end

    options =
      for {key, value} <- options, value != nil, do: "#{key} #{sql_value(value)}"

    "CREATE OR REPLACE SECRET #{secret_name(conn, scope)} (" <>
      Enum.join(["TYPE #{conn["type"]}" | options] ++ ["SCOPE #{Duck.literal(scope)}"], ", ") <>
      ")"
  end

  defp sql_value(value) when is_boolean(value), do: to_string(value)
  defp sql_value(value), do: Duck.literal(to_string(value))

  @doc "The secret's name: unique to the connection and scope, safe as an identifier."
  def secret_name(conn, scope) do
    hash = :crypto.hash(:sha256, conn["name"] <> "\0" <> scope) |> Base.encode16(case: :lower)
    "ixpipe_" <> binary_part(hash, 0, 16)
  end

  # The scheme and bucket (or container): s3://sales/2026/x.csv is s3://sales.
  defp scope(path) do
    [scheme, rest] = String.split(path, "://", parts: 2)
    scheme <> "://" <> (rest |> String.split("/", parts: 2) |> hd())
  end

  defp secret!(conn, key) do
    case Connections.secret(conn, key) do
      {:ok, value} -> value
      {:error, message} -> raise message
    end
  end
end
