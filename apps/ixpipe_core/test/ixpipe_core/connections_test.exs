defmodule IxpipeCore.ConnectionsTest do
  use ExUnit.Case, async: false
  alias IxpipeCore.Connections

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-conns-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  @warehouse %{
    "name" => "warehouse",
    "type" => "postgres",
    "host" => "localhost",
    "port" => 5432,
    "database" => "sales",
    "username" => "analyst",
    "password_env" => "WAREHOUSE_PASSWORD"
  }

  test "connections are saved, listed, read back and deleted", %{dir: dir} do
    assert Connections.list(dir) == []
    assert :ok = Connections.put(dir, @warehouse)

    assert :ok =
             Connections.put(dir, %{"name" => "local", "type" => "sqlite", "path" => "/data/x.db"})

    assert Enum.map(Connections.list(dir), & &1["name"]) == ["local", "warehouse"]
    assert {:ok, @warehouse} = Connections.get(dir, "warehouse")
    assert File.exists?(Path.join(dir, "connections.yaml"))

    assert :ok = Connections.delete(dir, "local")
    assert Enum.map(Connections.list(dir), & &1["name"]) == ["warehouse"]
  end

  test "saving a connection with the same name replaces it", %{dir: dir} do
    :ok = Connections.put(dir, @warehouse)
    :ok = Connections.put(dir, %{@warehouse | "host" => "db.internal"})
    assert [%{"host" => "db.internal"}] = Connections.list(dir)
  end

  test "an unknown connection says so", %{dir: dir} do
    assert {:error, "No saved connection named nope"} = Connections.get(dir, "nope")
  end

  test "passwords are never written to disk", %{dir: dir} do
    assert {:error, message} = Connections.put(dir, Map.put(@warehouse, "password", "s3cret"))
    assert message =~ "password_env"
    refute File.exists?(Path.join(dir, "connections.yaml"))
  end

  test "connections are checked before they are saved", %{dir: dir} do
    assert {:error, "Give the connection a name"} =
             Connections.put(dir, Map.delete(@warehouse, "name"))

    assert {:error,
            "Choose a connection type: postgres, mysql, sqlserver, sqlite, s3, gcs or azure"} =
             Connections.put(dir, %{@warehouse | "type" => "oracle"})

    assert {:error, "A postgres connection needs host, database and username"} =
             Connections.put(dir, Map.delete(@warehouse, "host"))

    assert {:error, "A sqlite connection needs a path"} =
             Connections.put(dir, %{"name" => "x", "type" => "sqlite"})
  end

  test "dir/0 is IXPIPE_HOME, else ~/ixpipe" do
    previous = System.get_env("IXPIPE_HOME")

    on_exit(fn ->
      if previous,
        do: System.put_env("IXPIPE_HOME", previous),
        else: System.delete_env("IXPIPE_HOME")
    end)

    System.put_env("IXPIPE_HOME", "/somewhere")
    assert Connections.dir() == "/somewhere"
    System.delete_env("IXPIPE_HOME")
    assert Connections.dir() == Path.expand("~/ixpipe")
  end

  test "the password comes from the environment variable it names", %{dir: dir} do
    :ok = Connections.put(dir, @warehouse)
    System.delete_env("WAREHOUSE_PASSWORD")

    assert {:error,
            "Set the environment variable WAREHOUSE_PASSWORD to the password for connection warehouse"} =
             Connections.password(@warehouse)

    System.put_env("WAREHOUSE_PASSWORD", "pw")
    on_exit(fn -> System.delete_env("WAREHOUSE_PASSWORD") end)
    assert {:ok, "pw"} = Connections.password(@warehouse)
  end

  test "MySQL and SQL Server connections need a host, database and username", %{dir: dir} do
    for type <- ~w(mysql sqlserver) do
      assert :ok = Connections.put(dir, %{@warehouse | "type" => type, "name" => type})

      assert {:error, "A #{type} connection needs host, database and username"} ==
               Connections.put(dir, %{"name" => "x", "type" => type})
    end
  end

  test "cloud storage connections keep their secrets in the environment", %{dir: dir} do
    lake = %{
      "name" => "lake",
      "type" => "s3",
      "key_id" => "AKIA1",
      "secret_env" => "LAKE_SECRET",
      "region" => "eu-west-1"
    }

    assert :ok = Connections.put(dir, lake)
    assert {:ok, ^lake} = Connections.get(dir, "lake")

    assert {:error, "An s3 connection needs key_id and secret_env"} =
             Connections.put(dir, Map.delete(lake, "secret_env"))

    assert {:error, "An azure connection needs a connection_string_env"} =
             Connections.put(dir, %{"name" => "blob", "type" => "azure"})

    for key <- ~w(secret connection_string session_token) do
      assert {:error, message} = Connections.put(dir, Map.put(lake, key, "x"))
      assert message =~ "aren't saved"
    end

    System.delete_env("LAKE_SECRET")

    assert {:error, "Set the environment variable LAKE_SECRET to the secret for connection lake"} =
             Connections.secret(lake, "secret_env")

    System.put_env("LAKE_SECRET", "shh")
    on_exit(fn -> System.delete_env("LAKE_SECRET") end)
    assert {:ok, "shh"} = Connections.secret(lake, "secret_env")
    assert {:ok, nil} = Connections.secret(lake, "session_token_env")
  end
end
