defmodule IxpipeCore.Connections do
  @moduledoc """
  Saved database connections, in `connections.yaml` in the workflows home
  (`IXPIPE_HOME`). A workflow names one in a tool's `connection` setting.

  Each connection has a `name`, a `type` and its settings:

  | Type | Settings |
  | --- | --- |
  | `postgres`, `mysql`, `sqlserver` | `host`, `port`, `database`, `username`, `password_env` (`sqlserver`: `ssl`) |
  | `sqlite` | `path` |
  | `s3` | `key_id`, `secret_env`, `region`, `endpoint`, `session_token_env`, `url_style`, `use_ssl` |
  | `gcs` | `key_id`, `secret_env` (an HMAC key) |
  | `azure` | `connection_string_env` |

  Secrets are never saved: a setting ending in `_env` names the environment
  variable that holds one.
  """

  @file_name "connections.yaml"
  @types [
    {"postgres", ~w(host database username)},
    {"mysql", ~w(host database username)},
    {"sqlserver", ~w(host database username)},
    {"sqlite", ~w(path)},
    {"s3", ~w(key_id secret_env)},
    {"gcs", ~w(key_id secret_env)},
    {"azure", ~w(connection_string_env)}
  ]
  @required Map.new(@types)
  # Secrets someone may try to save in place of the variable that holds them.
  @secrets ~w(secret connection_string session_token)

  @doc "The connection types, in the order an editor lists them."
  @spec types() :: [String.t()]
  def types, do: Enum.map(@types, &elem(&1, 0))

  @type connection :: %{String.t() => term()}

  @doc "The workflows home: `IXPIPE_HOME`, else `~/ixpipe`."
  @spec dir() :: Path.t()
  def dir, do: System.get_env("IXPIPE_HOME") || Path.expand("~/ixpipe")

  @doc "Every saved connection in `dir`, by name."
  @spec list(Path.t()) :: [connection()]
  def list(dir) do
    case File.read(Path.join(dir, @file_name)) do
      {:ok, yaml} ->
        {:ok, doc} = YamlElixir.read_from_string(yaml)
        Enum.sort_by((doc || %{})["connections"] || [], & &1["name"])

      {:error, :enoent} ->
        []
    end
  end

  @doc "The connection named `name` in `dir`."
  @spec get(Path.t(), String.t()) :: {:ok, connection()} | {:error, String.t()}
  def get(dir, name) do
    case Enum.find(list(dir), &(&1["name"] == name)) do
      nil -> {:error, "No saved connection named #{name}"}
      conn -> {:ok, conn}
    end
  end

  @doc "Saves `conn` in `dir`, replacing any connection with its name."
  @spec put(Path.t(), connection()) :: :ok | {:error, String.t()}
  def put(dir, conn) do
    with :ok <- check(conn) do
      write(dir, [conn | Enum.reject(list(dir), &(&1["name"] == conn["name"]))])
    end
  end

  @doc "Removes the connection named `name` from `dir`."
  @spec delete(Path.t(), String.t()) :: :ok
  def delete(dir, name), do: write(dir, Enum.reject(list(dir), &(&1["name"] == name)))

  @doc "The password for `conn`, from the environment variable its `password_env` names."
  @spec password(connection()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def password(conn), do: secret(conn, "password_env")

  @doc """
  The secret for `conn` from the environment variable its setting `key`
  (`password_env`, `secret_env`, …) names; nil when the setting is absent.
  """
  @spec secret(connection(), String.t()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def secret(conn, key) do
    case conn[key] do
      var when is_binary(var) and var != "" ->
        case System.get_env(var) do
          nil ->
            what = key |> String.replace_suffix("_env", "") |> String.replace("_", " ")

            {:error,
             "Set the environment variable #{var} to the #{what} for connection #{conn["name"]}"}

          value ->
            {:ok, value}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp check(conn) do
    cond do
      Map.has_key?(conn, "password") ->
        {:error,
         "Passwords aren't saved. Put the password in an environment variable and set password_env to its name"}

      Enum.any?(@secrets, &Map.has_key?(conn, &1)) ->
        {:error,
         "Secrets aren't saved. Put the secret in an environment variable and set the setting ending in _env to its name"}

      blank?(conn["name"]) ->
        {:error, "Give the connection a name"}

      not Map.has_key?(@required, conn["type"]) ->
        {:error, "Choose a connection type: " <> join(types(), "or")}

      Enum.any?(@required[conn["type"]], &blank?(conn[&1])) ->
        case @required[conn["type"]] do
          [only] -> {:error, "#{article(conn["type"])} connection needs a #{only}"}
          keys -> {:error, "#{article(conn["type"])} connection needs #{join(keys, "and")}"}
        end

      true ->
        :ok
    end
  end

  defp article(type) when type in ~w(s3 azure), do: "An #{type}"
  defp article(type), do: "A #{type}"

  defp blank?(value), do: value in [nil, ""]

  @doc false
  def join(words, conjunction) do
    {init, [last]} = Enum.split(words, -1)
    Enum.join(init, ", ") <> " #{conjunction} " <> last
  end

  # JSON is YAML, and Jason quotes every string safely.
  defp write(dir, conns) do
    File.mkdir_p!(dir)
    doc = %{"connections" => Enum.sort_by(conns, & &1["name"])}
    File.write!(Path.join(dir, @file_name), Jason.encode!(doc, pretty: true) <> "\n")
  end
end
