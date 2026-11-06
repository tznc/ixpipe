defmodule IxpipeCore.CloudTest do
  # Needs an S3-compatible server and DuckDB's httpfs extension (downloaded
  # on first use): see AGENTS.md (`mix test --only s3`). The endpoint comes
  # from IXPIPE_S3_ENDPOINT (default localhost:5000, moto_server's port).
  use ExUnit.Case, async: false
  alias IxpipeCore.{Connections, Context, Table, Tools}

  @moduletag :s3

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-s3-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    endpoint = System.get_env("IXPIPE_S3_ENDPOINT", "localhost:5000")
    bucket = "ixpipe-#{System.unique_integer([:positive])}"
    create_bucket!(endpoint, bucket)

    System.put_env("IXPIPE_S3_SECRET", "secret")

    :ok =
      Connections.put(dir, %{
        "name" => "lake",
        "type" => "s3",
        "key_id" => "test",
        "secret_env" => "IXPIPE_S3_SECRET",
        "region" => "us-east-1",
        "endpoint" => endpoint,
        "url_style" => "path",
        "use_ssl" => false
      })

    %{config: %{"connection" => "lake", "_home" => dir}, bucket: bucket, ctx: Context.new()}
  end

  # A bare HTTP PUT: S3 servers for tests accept it unsigned.
  defp create_bucket!(endpoint, bucket) do
    [host, port] = String.split(endpoint, ":")

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), String.to_integer(port), [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        "PUT /#{bucket} HTTP/1.1\r\nHost: #{endpoint}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      )

    {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(socket, 0)
    :gen_tcp.close(socket)
  end

  test "CSV, Parquet and JSON round-trip through a bucket", %{
    config: config,
    bucket: bucket,
    ctx: ctx
  } do
    src = Table.new(ctx.db, "src", id: [1, 2], name: ["Ada", "Grace"])

    for {format, out, input} <- [
          {"csv", Tools.OutputCsv, Tools.InputCsv},
          {"parquet", Tools.OutputParquet, Tools.InputParquet},
          {"json", Tools.OutputJson, Tools.InputJson}
        ] do
      path = "s3://#{bucket}/out/data.#{format}"
      assert out.run(%{"in" => src}, Map.put(config, "path", path), ctx) == src
      back = input.run(%{}, Map.put(config, "path", path), ctx)
      assert Table.to_columns(back) == %{"id" => [1, 2], "name" => ["Ada", "Grace"]}
    end
  end

  test "a folder in a bucket reads every file of the format", %{
    config: config,
    bucket: bucket,
    ctx: ctx
  } do
    for n <- 1..2 do
      t = Table.new(ctx.db, "part#{n}", id: [n])

      Tools.OutputCsv.run(
        %{"in" => t},
        Map.put(config, "path", "s3://#{bucket}/parts/#{n}.csv"),
        ctx
      )
    end

    df = Tools.InputCsv.run(%{}, Map.put(config, "path", "s3://#{bucket}/parts/"), ctx)
    assert df |> Table.to_columns() |> Map.fetch!("id") |> Enum.sort() == [1, 2]
  end
end
