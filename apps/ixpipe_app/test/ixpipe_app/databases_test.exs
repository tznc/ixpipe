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

    for tool <- ~w(input_sqlite input_postgres output_sqlite),
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
end
