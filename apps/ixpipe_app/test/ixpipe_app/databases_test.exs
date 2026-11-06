defmodule IxpipeApp.DatabasesTest do
  # Database tools in the app: the palette, saved connections to choose from
  # in the properties panel, and runs that find connections in the
  # workflows folder.
  use ExUnit.Case, async: false
  alias Baguette.Test
  alias IxpipeCore.Connections

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-db-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    db = Path.join(dir, "shop.db")

    :ok =
      IxpipeCore.Sqlite.execute(
        db,
        "CREATE TABLE orders (id INTEGER, amount REAL); INSERT INTO orders VALUES (1, 50.5), (2, 5.0);"
      )

    File.write!(Path.join(dir, "flow.yaml"), "name: flow\nnodes: []\n")
    %{dir: dir, db: db, w: System.unique_integer([:positive])}
  end

  defp start(%{dir: dir, w: w}) do
    pid =
      start_supervised!(
        {IxpipeApp.MainView,
         window: w, theme: IxpipeApp.Theme, args: [dir: dir, path: Path.join(dir, "flow.yaml")]}
      )

    {w, pid}
  end

  test "database tools are on the In/Out tab", ctx do
    {w, _} = start(ctx)
    Test.click(w, "In/Out tab")

    for tool <-
          ~w(input_sqlite input_postgres input_mysql input_sqlserver input_json
             output_sqlite output_postgres output_mysql output_sqlserver output_json),
        do: assert(IxpipeApp.UI.find(w, "Add #{tool}") != [])
  end

  test "without saved connections, the Connection setting says where to add them", ctx do
    {w, _} = start(ctx)
    IxpipeApp.UI.add(w, "input_postgres")
    assert Test.text(w) =~ "No saved connections yet"
    assert Test.text(w) =~ "connections.yaml"
  end

  test "saved connections of the tool's type are choices", ctx do
    :ok = Connections.put(ctx.dir, %{"name" => "shop", "type" => "sqlite", "path" => ctx.db})

    :ok =
      Connections.put(ctx.dir, %{
        "name" => "warehouse",
        "type" => "postgres",
        "host" => "localhost",
        "database" => "dw",
        "username" => "me",
        "password_env" => "DW_PASSWORD"
      })

    {w, pid} = start(ctx)
    IxpipeApp.UI.add(w, "input_sqlite")
    assert Test.find_all(w, "Connection shop") != []
    assert Test.find_all(w, "Connection warehouse") == []

    Test.click(w, "Connection shop")
    assert hd(:sys.get_state(pid).assigns.spec.nodes).config["connection"] == "shop"
  end

  test "a run reads through a saved connection in the workflows folder", ctx do
    :ok = Connections.put(ctx.dir, %{"name" => "shop", "type" => "sqlite", "path" => ctx.db})
    {w, pid} = start(ctx)

    IxpipeApp.UI.add(w, "input_sqlite")
    Test.click(w, "Connection shop")
    Test.fill(w, "Table", "orders")
    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "Run succeeded"
    assert Test.text(w) =~ "2 rows"

    # The folder is supplied at run time, never saved into the workflow.
    refute Map.has_key?(hd(:sys.get_state(pid).assigns.spec.nodes).config, "_home")
  end

  test "MySQL and SQL Server tools list their own kind of connection", ctx do
    for {name, type} <- [{"shop_my", "mysql"}, {"shop_ms", "sqlserver"}] do
      :ok =
        Connections.put(ctx.dir, %{
          "name" => name,
          "type" => type,
          "host" => "localhost",
          "database" => "dw",
          "username" => "me"
        })
    end

    {w, _} = start(ctx)
    IxpipeApp.UI.add(w, "output_sqlserver")
    assert Test.find_all(w, "Connection shop_ms") != []
    assert Test.find_all(w, "Connection shop_my") == []
  end

  test "file tools offer cloud connections, and a second click clears one", ctx do
    :ok =
      Connections.put(ctx.dir, %{
        "name" => "lake",
        "type" => "s3",
        "key_id" => "k",
        "secret_env" => "LAKE_SECRET"
      })

    {w, pid} = start(ctx)
    IxpipeApp.UI.add(w, "input_csv")
    assert Test.text(w) =~ "Cloud connection"
    Test.click(w, "Connection lake")
    assert hd(:sys.get_state(pid).assigns.spec.nodes).config["connection"] == "lake"
    Test.click(w, "Connection lake")
    refute Map.has_key?(hd(:sys.get_state(pid).assigns.spec.nodes).config, "connection")
  end

  test "without cloud connections, the setting says they are optional for public buckets", ctx do
    {w, _} = start(ctx)
    IxpipeApp.UI.add(w, "output_parquet")
    assert Test.text(w) =~ "No saved cloud connections yet"
  end

  test "the Excel sheet setting offers the workbook's sheets", ctx do
    path = Path.join(ctx.dir, "book.xlsx")

    workbook = %Elixlsx.Workbook{
      sheets: [%Elixlsx.Sheet{name: "Orders", rows: [["id"], [1]]}, %Elixlsx.Sheet{name: "Notes"}]
    }

    {:ok, _} = Elixlsx.write_to(workbook, String.to_charlist(path))
    {w, pid} = start(ctx)
    IxpipeApp.UI.add(w, "input_excel")
    assert Test.find_all(w, "Sheet Notes") == []

    Test.fill(w, "File", path)
    Test.click(w, "Sheet Notes")
    assert hd(:sys.get_state(pid).assigns.spec.nodes).config["sheet"] == "Notes"
  end

  test "the home screen doesn't list connections.yaml as a workflow", ctx do
    :ok = Connections.put(ctx.dir, %{"name" => "shop", "type" => "sqlite", "path" => ctx.db})
    w = ctx.w

    start_supervised!(
      {IxpipeApp.MainView, window: w, theme: IxpipeApp.Theme, args: [dir: ctx.dir]}
    )

    assert Test.text(w) =~ "flow.yaml"
    refute Test.text(w) =~ "connections.yaml"
  end
end
