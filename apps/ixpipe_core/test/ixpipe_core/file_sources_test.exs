defmodule IxpipeCore.FileSourcesTest do
  # Many files at once (folders and wildcards), JSON, Excel ranges, and the
  # cloud storage paths the file tools take.
  use ExUnit.Case, async: true
  alias IxpipeCore.{Cloud, Connections, Context, Table, Tools}

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-sources-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, ctx: Context.new()}
  end

  defp files!(dir) do
    folder = Path.join(dir, "orders")
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "jan.csv"), "id,amount\n1,10\n2,20\n")
    # Columns in another order, and one more: unioned by name.
    File.write!(Path.join(folder, "feb.csv"), "amount,id,note\n30,3,late\n")
    File.write!(Path.join(folder, "readme.txt"), "not data\n")
    folder
  end

  describe "folders and wildcards" do
    test "a folder reads every CSV in it, unioned by name", %{dir: dir, ctx: ctx} do
      df = Tools.InputCsv.run(%{}, %{"path" => files!(dir)}, ctx)
      assert Table.columns(df) == ["amount", "id", "note"]
      rows = df |> Table.rows() |> Enum.sort_by(& &1["id"])
      assert Enum.map(rows, & &1["id"]) == [1, 2, 3]
      assert Enum.map(rows, & &1["note"]) == [nil, nil, "late"]
    end

    test "a wildcard picks the files, with an optional file name column", %{dir: dir, ctx: ctx} do
      folder = files!(dir)

      df =
        Tools.InputCsv.run(%{}, %{"path" => Path.join(folder, "j*.csv"), "filename" => true}, ctx)

      assert Table.to_columns(df)["filename"] == List.duplicate(Path.join(folder, "jan.csv"), 2)
    end

    test "nothing matching says so", %{dir: dir, ctx: ctx} do
      pattern = Path.join(dir, "*.parquet")

      assert_raise RuntimeError,
                   "No files match #{pattern}. Check the path, or choose a file or folder that has some.",
                   fn -> Tools.InputParquet.run(%{}, %{"path" => pattern}, ctx) end
    end

    test "Parquet folders read too", %{dir: dir, ctx: ctx} do
      for {name, n} <- [{"a", 1}, {"b", 2}] do
        t = Table.new(ctx.db, "src_#{name}", id: [n])
        Tools.OutputParquet.run(%{"in" => t}, %{"path" => Path.join(dir, "#{name}.parquet")}, ctx)
      end

      df = Tools.InputParquet.run(%{}, %{"path" => dir, "filename" => true}, ctx)
      assert df |> Table.to_columns() |> Map.fetch!("id") |> Enum.sort() == [1, 2]
      assert Table.columns(df) == ["id", "filename"]
    end
  end

  describe "JSON" do
    test "output_json writes an array that input_json reads back", %{dir: dir, ctx: ctx} do
      src = Table.new(ctx.db, "src", id: [1, 2], name: ["Ada", nil])
      path = Path.join(dir, "out.json")
      assert Tools.OutputJson.run(%{"in" => src}, %{"path" => path}, ctx) == src
      assert {:ok, [%{"id" => 1, "name" => "Ada"}, %{"id" => 2}]} = Jason.decode(File.read!(path))

      back = Tools.InputJson.run(%{}, %{"path" => path}, ctx)
      assert Table.to_columns(back) == %{"id" => [1, 2], "name" => ["Ada", nil]}
    end

    test "output_json writes one object per line when asked", %{dir: dir, ctx: ctx} do
      src = Table.new(ctx.db, "src", id: [1, 2])
      path = Path.join(dir, "out.ndjson")
      Tools.OutputJson.run(%{"in" => src}, %{"path" => path, "lines" => true}, ctx)
      assert File.read!(path) == ~s({"id":1}\n{"id":2}\n)
      assert Table.count(Tools.InputJson.run(%{}, %{"path" => path}, ctx)) == 2
    end

    test "input_json reads a folder of JSON files", %{dir: dir, ctx: ctx} do
      File.write!(Path.join(dir, "a.json"), ~s([{"id": 1, "tags": ["x"]}]))
      File.write!(Path.join(dir, "b.json"), ~s({"id": 2, "extra": true}))

      df = Tools.InputJson.run(%{}, %{"path" => dir}, ctx)
      assert Table.columns(df) == ["id", "tags", "extra"]
      assert df |> Table.to_columns() |> Map.fetch!("id") |> Enum.sort() == [1, 2]
    end
  end

  describe "Excel ranges and sheets" do
    defp grid!(dir) do
      path = Path.join(dir, "grid.xlsx")

      sheet = %Elixlsx.Sheet{
        name: "Report",
        rows: [
          ["Sales report"],
          [],
          [nil, "id", "amount", "note"],
          [nil, 1, 10, "a"],
          [nil, 2, 20, "b"],
          [nil, 3, 30, "c"],
          [],
          [nil, "Total", 60]
        ]
      }

      workbook = %Elixlsx.Workbook{sheets: [sheet, %Elixlsx.Sheet{name: "Notes", rows: [["x"]]}]}
      {:ok, _} = Elixlsx.write_to(workbook, String.to_charlist(path))
      path
    end

    test "a cell range picks the table out of a sheet", %{dir: dir, ctx: ctx} do
      df = Tools.InputExcel.run(%{}, %{"path" => grid!(dir), "range" => "B3:C5"}, ctx)
      assert Table.to_columns(df) == %{"id" => [1, 2], "amount" => [10, 20]}
    end

    test "an open-ended range reads to the sheet's end, without blank rows", %{dir: dir, ctx: ctx} do
      df = Tools.InputExcel.run(%{}, %{"path" => grid!(dir), "range" => "b3:d"}, ctx)
      assert Table.columns(df) == ["id", "amount", "note"]
      # The blank row between the table and its total is left out.
      assert Table.count(df) == 4
      assert List.last(Table.to_columns(df)["id"]) == "Total"
    end

    test "a range that isn't one says how to write it", %{dir: dir, ctx: ctx} do
      assert_raise RuntimeError,
                   "B3-C5 isn't a cell range. Write one like A1:D20, or B3:D to read to the end.",
                   fn ->
                     Tools.InputExcel.run(%{}, %{"path" => grid!(dir), "range" => "B3-C5"}, ctx)
                   end
    end

    test "the sheet setting suggests the workbook's sheets", %{dir: dir} do
      path = grid!(dir)
      assert Tools.InputExcel.suggestions("sheet", %{"path" => path}) == ["Report", "Notes"]
      assert Tools.InputExcel.suggestions("sheet", %{"path" => Path.join(dir, "no.xlsx")}) == []
      assert Tools.InputExcel.suggestions("sheet", %{}) == []
    end
  end

  describe "cloud storage" do
    test "paths are local or in a cloud" do
      assert Cloud.kind("s3://bucket/data/*.csv") == "s3"
      assert Cloud.kind("gs://bucket/x.parquet") == "gcs"
      assert Cloud.kind("az://container/x.json") == "azure"
      assert Cloud.kind("abfss://c@acct.dfs.core.windows.net/x.csv") == "azure"
      assert Cloud.kind("/home/me/x.csv") == nil
      assert Cloud.kind("C:\\data\\x.csv") == nil
    end

    test "a saved connection becomes a DuckDB secret scoped to the bucket" do
      System.put_env("LAKE_SECRET_TEST", "it's secret")
      on_exit(fn -> System.delete_env("LAKE_SECRET_TEST") end)

      conn = %{
        "name" => "lake",
        "type" => "s3",
        "key_id" => "AKIA1",
        "secret_env" => "LAKE_SECRET_TEST",
        "region" => "eu-west-1",
        "endpoint" => "localhost:9000",
        "url_style" => "path",
        "use_ssl" => false
      }

      assert Cloud.secret_sql(conn, "s3://sales/2026/*.csv") ==
               "CREATE OR REPLACE SECRET " <>
                 Cloud.secret_name(conn, "s3://sales") <>
                 " (TYPE s3, KEY_ID 'AKIA1', SECRET 'it''s secret', REGION 'eu-west-1', " <>
                 "ENDPOINT 'localhost:9000', URL_STYLE 'path', USE_SSL false, SCOPE 's3://sales')"

      System.put_env("BLOB_TEST", "DefaultEndpointsProtocol=https;AccountName=a")
      on_exit(fn -> System.delete_env("BLOB_TEST") end)
      blob = %{"name" => "blob", "type" => "azure", "connection_string_env" => "BLOB_TEST"}

      assert Cloud.secret_sql(blob, "az://raw/x.csv") ==
               "CREATE OR REPLACE SECRET " <>
                 Cloud.secret_name(blob, "az://raw") <>
                 " (TYPE azure, CONNECTION_STRING 'DefaultEndpointsProtocol=https;AccountName=a', SCOPE 'az://raw')"
    end

    test "a connection for another cloud says which kind the path needs", %{dir: dir, ctx: ctx} do
      :ok =
        Connections.put(dir, %{
          "name" => "lake",
          "type" => "s3",
          "key_id" => "k",
          "secret_env" => "NOPE"
        })

      assert_raise RuntimeError,
                   "Connection lake is s3, but gs://b/x.csv needs a gcs connection. Choose one, or no connection for a public bucket.",
                   fn ->
                     Tools.InputCsv.run(
                       %{},
                       %{"path" => "gs://b/x.csv", "connection" => "lake", "_home" => dir},
                       ctx
                     )
                   end
    end

    test "a missing extension says what happened and what to do" do
      message =
        Cloud.extension_error("httpfs", "IO Error: Failed to download extension \"httpfs\"")

      assert message =~ "Couldn't load DuckDB's httpfs extension"
      assert message =~ "Connect to the internet"
    end
  end
end
