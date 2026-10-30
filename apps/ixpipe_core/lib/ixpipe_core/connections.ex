defmodule IxpipeCore.Connections do
  @moduledoc """
  Saved database connections, in `connections.yaml` in the workflows home
  (`IXPIPE_HOME`). A workflow names one in a tool's `connection` setting.

  Each connection has a `name`, a `type` (`postgres` or `sqlite`) and its
  settings: `host`, `port`, `database`, `username` and `password_env` for
  Postgres, `path` for SQLite. Passwords are never saved: `password_env` names
  the environment variable that holds one.
  """

  @file_name "connections.yaml"
  @types %{"postgres" => ~w(host database username), "sqlite" => ~w(path)}

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
  def password(%{"password_env" => var} = conn) when is_binary(var) and var != "" do
    case System.get_env(var) do
      nil ->
        {:error,
         "Set the environment variable #{var} to the password for connection #{conn["name"]}"}

      password ->
        {:ok, password}
    end
  end

  def password(_conn), do: {:ok, nil}

  defp check(conn) do
    cond do
      Map.has_key?(conn, "password") ->
        {:error,
         "Passwords aren't saved. Put the password in an environment variable and set password_env to its name"}

      blank?(conn["name"]) ->
        {:error, "Give the connection a name"}

      not Map.has_key?(@types, conn["type"]) ->
        {:error, "Choose a connection type: postgres or sqlite"}

      Enum.any?(@types[conn["type"]], &blank?(conn[&1])) ->
        case @types[conn["type"]] do
          [only] -> {:error, "A #{conn["type"]} connection needs a #{only}"}
          keys -> {:error, "A #{conn["type"]} connection needs #{join(keys)}"}
        end

      true ->
        :ok
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp join(keys) do
    {init, [last]} = Enum.split(keys, -1)
    Enum.join(init, ", ") <> " and " <> last
  end

  # JSON is YAML, and Jason quotes every string safely.
  defp write(dir, conns) do
    File.mkdir_p!(dir)
    doc = %{"connections" => Enum.sort_by(conns, & &1["name"])}
    File.write!(Path.join(dir, @file_name), Jason.encode!(doc, pretty: true) <> "\n")
  end
end
