defmodule IxpipeApp.QA.CanvasTest do
  # Screenshot QA of the home screen and canvas. Captures land in
  # test/qa/.shots as <name>.png with <name>.json expectations: open each
  # PNG and check every claim (see .claude/skills/app-qa).
  use ExUnit.Case, async: false
  alias Baguette.Playwright
  alias IxpipeApp.QA

  @moduletag :qa

  describe "home" do
    setup do
      qa = QA.launch!()
      on_exit(fn -> QA.stop(qa) end)
      qa
    end

    test "lists the workflows", %{page: page} do
      assert :ok = Playwright.await_text(page, "sales.yaml")
      assert :ok = Playwright.await_text(page, "scratch.yaml")

      QA.capture(page, "home-01-list", [
        "A 'Workflows' title, left-aligned, with a teal 'New workflow' button on the right",
        "sales.yaml, scratch.yaml and split.yaml listed as rows, each with a muted relative time on the right",
        "Greyscale apart from the one teal button; nothing centred"
      ])
    end
  end

  describe "canvas" do
    setup do
      qa = QA.launch!(open: "sales.yaml")
      on_exit(fn -> QA.stop(qa) end)
      qa
    end

    test "shows the seeded workflow", %{page: page} do
      assert :ok = Playwright.await_text(page, "customers")

      QA.capture(page, "canvas-01-sales", [
        "Breadcrumb 'Workflows / sales.yaml' over title 'sales'; Save workflow outlined, Run workflow teal",
        "Six cards, none overlapping, joined by S-curves; a join's two inputs arrive one above the other",
        "Tools sidebar (eleven tools) left; 'Nothing selected' panel right; Results says to select a tool"
      ])
    end

    test "run shows row counts on every node", %{page: page} do
      Playwright.click(page, "Run workflow")
      assert :ok = Playwright.await_text(page, "Run succeeded")

      QA.capture(page, "canvas-02-run", [
        "A green-tinted callout bottom-left titled 'Run succeeded'; nothing in the layout moved",
        "Every node card shows a green row-count pill: orders 4, customers 3, joined 4, totals 3, sorted 3, out 3"
      ])
    end

    test "connecting highlights the source node", %{page: page} do
      Playwright.click(page, "Connect from orders")
      assert :ok = Playwright.await_text(page, "Connecting from orders")

      QA.capture(page, "canvas-03-connecting", [
        "The orders card has a teal border and teal tint; no other card does",
        "A teal-tinted callout bottom-left titled 'Connecting from orders'"
      ])
    end

    test "selecting a tool shows its settings", %{page: page} do
      Playwright.click(page, "Select joined")
      assert :ok = Playwright.await(page, role: "textbox", name: "Join on")
      assert Playwright.input_value(page, "Join on") == "customer_id"

      QA.capture(page, "canvas-04-properties", [
        "The joined card has a teal border; the right panel is titled 'joined', caption 'Join'",
        "'Join on' label above an input reading customer_id; 'Join type' with inner highlighted in teal",
        "Labels above inputs, all inputs the same width, nothing centred"
      ])
    end

    test "results show the selected tool's rows after a run", %{page: page} do
      Playwright.click(page, "Run workflow")
      assert :ok = Playwright.await_text(page, "Run succeeded")
      Playwright.click(page, "Select totals")
      assert :ok = Playwright.await_text(page, "totals · 3 rows")

      QA.capture(page, "canvas-05-results", [
        "Results under the canvas: caption 'totals · 3 rows', header row 'name' and 'total' in label style",
        "Three rows: Ada 80, Bob 5, Cy 12 (in any order); totals right-aligned",
        "The right panel shows totals' Group by and Aggregates settings"
      ])
    end

    test "an invalid setting shows why, under its input", %{page: page} do
      Playwright.click(page, "Select joined")
      Playwright.fill(page, "Join on", "")
      assert :ok = Playwright.await_text(page, "Required")

      QA.capture(page, "canvas-06-invalid", [
        "Under 'Join on' a red caption reads 'Required'; the input is empty",
        "Nothing else on the screen moved or changed colour"
      ])
    end
  end

  describe "view" do
    setup do
      qa = QA.launch!(open: "sales.yaml")
      on_exit(fn -> QA.stop(qa) end)
      qa
    end

    test "undo, zoom and pan", %{page: page} do
      Playwright.click(page, "Remove customers")
      Playwright.click(page, "Undo")
      assert :ok = Playwright.await(page, role: "button", name: "Select customers")
      Playwright.click(page, "Zoom out")
      assert :ok = Playwright.await_text(page, "75%")

      QA.capture(page, "canvas-09-view", [
        "Ribbon Home tab selected: Edit group (undo and redo arrow icons beside Undo, dimmed, and Redo) and View group (zoom-out and zoom-in magnifier icons around 75%, a scan icon beside Restore view)",
        "All six cards (customers restored) compact (name and tool only), none overlapping, wires following them",
        "Nothing in the panels or header moved"
      ])
    end

    test "the ribbon's tool tabs", %{page: page} do
      Playwright.click(page, role: "tab", name: "In/Out tab")
      assert :ok = Playwright.await(page, role: "button", name: "Add input_sqlite")

      QA.capture(page, "canvas-10-ribbon", [
        "Ribbon under the header: tabs Home, In/Out (selected: teal tint), Preparation, Join, Parse, Transform; header Save workflow has a floppy icon, Run workflow a play icon",
        "Groups Input (CSV, Excel, Parquet, JSON, SQLite, Postgres, MySQL, SQL Server) and Output (same), each command an icon (file, spreadsheet, box, braces, database, server, database-zap, server-cog) before its name, a caption beneath each group",
        "No tools sidebar: the canvas starts at the left edge"
      ])
    end

    test "the Transform and Preparation tabs' icons", %{page: page} do
      Playwright.click(page, role: "tab", name: "Transform tab")
      assert :ok = Playwright.await(page, role: "button", name: "Add transpose")

      QA.capture(page, "canvas-11-ribbon-transform", [
        "Transform tab selected: Aggregate (sigma icon, Summarize) and Reshape (table icon Cross tab, left-right arrows Transpose)",
        "Icons are the same grey as their labels, 16px, vertically centred with the text"
      ])

      Playwright.click(page, role: "tab", name: "Preparation tab")
      assert :ok = Playwright.await(page, role: "button", name: "Add data_cleansing")

      QA.capture(page, "canvas-12-ribbon-preparation", [
        "Columns (Select with a checklist icon, Formula with a function icon, Data cleansing with sparkles) and Rows (funnel Filter, arrows Sort, dice Sample, list-x Unique)",
        "No command lacks an icon; nothing wraps or clips"
      ])
    end

    test "keyboard shortcuts, and a tooltip naming one", %{page: page} do
      assert :ok = Playwright.await(page, role: "button", name: "Select customers")
      Playwright.click(page, "Remove customers")
      Playwright.press(page, "Control+z")
      assert :ok = Playwright.await(page, role: "button", name: "Select customers")
      Playwright.press(page, "Control+=")
      assert :ok = Playwright.await_text(page, "125%")
      Playwright.press(page, "Control+0")
      assert :ok = Playwright.await_text(page, "100%")
      Playwright.press(page, "Control+Enter")
      assert :ok = Playwright.await_text(page, "Run succeeded")
      Playwright.press(page, "Control+s")
      assert :ok = Playwright.await_text(page, "Saved sales.yaml")

      Playwright.hover(page, role: "button", name: "Undo")
      Process.sleep(1_000)

      QA.capture(page, "canvas-13-shortcuts", [
        "A tooltip 'Undo (Ctrl+Z)' under the Undo command",
        "A 'Saved sales.yaml' toast top right and a green 'Run succeeded' callout over the canvas",
        "Zoom back at 100%; all six cards present (customers restored by Ctrl+Z)"
      ])
    end
  end

  describe "multiple outputs" do
    setup do
      qa = QA.launch!(open: "split.yaml")
      on_exit(fn -> QA.stop(qa) end)
      qa
    end

    test "a filter's true and false outputs, wired and counted", %{page: page} do
      Playwright.click(page, "Run workflow")
      assert :ok = Playwright.await_text(page, "Run succeeded")
      Playwright.click(page, "Select big")
      Playwright.click(page, "Show false output")
      assert :ok = Playwright.await_text(page, "big.false · 2 rows")

      QA.capture(page, "canvas-07-outputs", [
        "The big card has two connectors, true and false, and pills 'true · 2 rows', 'false · 2 rows'",
        "Two curves leave big from different heights: true to large (above), false to small (below)",
        "Results shows big.false with the two small orders (amount 5 and 12), the 'false' switch highlighted"
      ])
    end
  end

  describe "file tools" do
    setup do
      book = Path.join(System.tmp_dir!(), "ixpipe-qa-#{System.unique_integer([:positive])}.xlsx")

      rows = [["region", "sales"], ["North", 120], ["South", 80], ["East", 95]]
      sheet = %Elixlsx.Sheet{name: "Regions", rows: rows}
      {:ok, _} = Elixlsx.write_to(%Elixlsx.Workbook{sheets: [sheet]}, book)

      qa = QA.launch!(open: "scratch.yaml", env: [{"BAGUETTE_PICK_FILE", book}])

      on_exit(fn ->
        QA.stop(qa)
        File.rm(book)
      end)

      Map.put(qa, :book, book)
    end

    test "an Excel input chosen with the file picker", %{page: page, book: book} do
      Playwright.click(page, role: "tab", name: "In/Out tab")
      Playwright.click(page, "Add input_excel")
      Playwright.click(page, "Choose file")
      assert Playwright.input_value(page, "File") == book
      Playwright.click(page, "Run workflow")
      assert :ok = Playwright.await_text(page, "Run succeeded")
      assert :ok = Playwright.await_text(page, "North")

      QA.capture(page, "canvas-08-excel", [
        "One Input Excel card; the panel shows File (the workbook's path, a Choose… button), Sheet with a 'Regions' choice button over its input, Cell range, and the header switch",
        "Results lists region and sales: North 120, South 80, East 95, sales right-aligned",
        "The In/Out tab is selected; its Input and Output groups list Excel and Parquet"
      ])
    end
  end

  describe "connectors" do
    setup do
      qa = QA.launch!(open: "scratch.yaml")
      on_exit(fn -> QA.stop(qa) end)

      for conn <- [
            %{
              "name" => "warehouse",
              "type" => "postgres",
              "host" => "db.internal",
              "database" => "sales",
              "username" => "analyst",
              "password_env" => "WAREHOUSE_PASSWORD"
            },
            %{
              "name" => "reporting",
              "type" => "postgres",
              "host" => "db.internal",
              "database" => "reports",
              "username" => "analyst"
            },
            %{"name" => "lake", "type" => "s3", "key_id" => "AKIA", "secret_env" => "LAKE_SECRET"}
          ],
          do: :ok = IxpipeCore.Connections.put(qa.home, conn)

      qa
    end

    test "a Postgres output chooses a saved connection", %{page: page} do
      Playwright.click(page, role: "tab", name: "In/Out tab")
      Playwright.click(page, "Add output_postgres")
      Playwright.click(page, "Connection warehouse")
      assert :ok = Playwright.await(page, role: "textbox", name: "Table")

      QA.capture(page, "canvas-14-output-postgres", [
        "One Output Postgres card (server icon); the panel is titled output_postgres_1, caption 'Output Postgres'",
        "Connection lists reporting and warehouse as buttons, warehouse teal-tinted; a hint 'A saved Postgres connection' beneath",
        "Table input, then 'If the table exists' with replace highlighted and append"
      ])
    end

    test "a CSV input offers cloud connections", %{page: page} do
      Playwright.click(page, role: "tab", name: "In/Out tab")
      Playwright.click(page, "Add input_csv")
      assert :ok = Playwright.await_text(page, "Cloud connection")

      QA.capture(page, "canvas-15-input-csv-cloud", [
        "The panel shows File (hint naming folders, patterns and s3://, gs://, az://), an 'Add a file name column' switch, then 'Cloud connection' marked Optional",
        "Cloud connection lists one button, lake, not highlighted; the Postgres connections are not listed",
        "Labels above inputs, gap between fields even, nothing centred"
      ])
    end
  end
end
