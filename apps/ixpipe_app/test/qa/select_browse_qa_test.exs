defmodule IxpipeApp.QA.SelectBrowseTest do
  # Screenshot QA of Select's column editor and of Results as a browser
  # (pages, sorting, the profile), on a desktop and a phone.
  use ExUnit.Case, async: false
  alias Baguette.Playwright
  alias IxpipeApp.QA

  @moduletag :qa

  setup do
    qa = QA.launch!(open: "sales.yaml")
    on_exit(fn -> QA.stop(qa) end)
    assert :ok = Playwright.await_text(qa.page, "customers")
    qa
  end

  # Adds a Select fed by orders and runs, so its editor knows the columns.
  defp add_select(page, from \\ "orders", column \\ "amount") do
    Playwright.click(page, role: "tab", name: "Preparation tab")
    Playwright.click(page, "Add select")
    Playwright.click(page, "Connect from #{from}")
    Playwright.click(page, "Connect to select_1 in")
    Playwright.click(page, "Run workflow")
    assert :ok = Playwright.await_text(page, "Run succeeded")
    Playwright.click(page, "Select select_1")
    assert :ok = Playwright.await(page, role: "textbox", name: "Name of #{column}")
  end

  test "Select lists the input's columns", %{page: page} do
    add_select(page)
    Playwright.uncheck(page, "Keep customer_id")
    Playwright.fill(page, "Name of amount", "total")
    assert :ok = Playwright.await_text(page, "Renamed from amount")

    QA.capture(page, "select-01-editor", [
      "The right panel lists id, customer_id and amount, one row each: checkbox, name input, type button (BIGINT), up and down arrows",
      "customer_id's checkbox is clear; amount's name reads 'total' with a muted 'Renamed from amount' beneath",
      "'New columns' with keep highlighted in teal below the rows; nothing clipped at 320px"
    ])
  end

  test "Select's type picker", %{page: page} do
    add_select(page)
    Playwright.click(page, "Type of amount")
    Playwright.click(page, "Cast amount to VARCHAR")
    Playwright.click(page, "Type of id")
    assert :ok = Playwright.await(page, role: "textbox", name: "Another type for id")

    QA.capture(page, "select-02-types", [
      "amount's type button reads VARCHAR with a teal tint and the caption 'BIGINT → VARCHAR'",
      "Under id, chips: BIGINT (teal, current), VARCHAR, DOUBLE, DECIMAL(18,2), DATE, TIMESTAMP, BOOLEAN, wrapping, then an input 'Another type, e.g. DECIMAL(10,4)'",
      "A muted caption: 'A value that doesn't convert becomes NULL.'"
    ])
  end

  test "Results sorts by a column header", %{page: page} do
    Playwright.click(page, "Run workflow")
    assert :ok = Playwright.await_text(page, "Run succeeded")
    Playwright.click(page, "Select orders")
    assert :ok = Playwright.await_text(page, "orders · 4 rows")
    Playwright.click(page, "Sort by amount")
    Playwright.click(page, "Sort by amount")
    assert :ok = Playwright.await(page, role: "button", name: "Sort by amount")

    QA.capture(page, "browse-01-sorted", [
      "Results header: 'orders · 4 rows', then 'Rows 1–4', dimmed previous and next arrows, and Data (teal) / Profile buttons on the right",
      "Column headers id, customer_id, amount; amount has a down arrow and the rows run 50, 30, 12, 5",
      "Numbers right-aligned under right-aligned headers"
    ])
  end

  test "Results profiles each column", %{page: page} do
    Playwright.click(page, "Run workflow")
    assert :ok = Playwright.await_text(page, "Run succeeded")
    Playwright.click(page, "Select joined")
    Playwright.click(page, "Show profile")
    assert :ok = Playwright.await_text(page, "Distribution")

    QA.capture(page, "browse-02-profile", [
      "A table: Column, Type, Nulls, Distinct, Values, Distribution; one row per column of joined",
      "Numeric columns show 'min – max' and small grey bars; name shows its top values with counts, e.g. 'Ada (2), Bob (1), Cy (1)'",
      "Profile is the teal-tinted view button; nothing overlaps the canvas"
    ])
  end

  test "a Select warning after a run", %{page: page} do
    add_select(page, "customers", "name")
    Playwright.click(page, "Type of name")
    Playwright.click(page, "Cast name to BIGINT")
    Playwright.click(page, "Run workflow")
    assert :ok = Playwright.await_text(page, "Run succeeded with 1 warning")

    QA.capture(page, "select-03-warning", [
      "An amber-tinted callout bottom-left: 'Run succeeded with 1 warning', naming select_1 and name's 3 NULLs",
      "The select_1 card has a green '3 rows' pill and an amber '1 warning' pill",
      "Results shows an amber pill 'name: 3 values couldn't become BIGINT and are now NULL.'"
    ])
  end

  test "on a phone, Results is a pane that browses", %{page: page} do
    :ok = Playwright.resize(page, 390, 844)
    assert :ok = Playwright.await(page, role: "tab", name: "Show canvas")
    Playwright.click(page, "Select orders")
    Playwright.click(page, "Run workflow")
    assert :ok = Playwright.await(page, role: "button", name: "Sort by id")

    QA.capture(page, "phone-browse-01", [
      "Results fills the pane: 'orders · 4 rows', 'Rows 1–4', 40px previous/next and Data/Profile buttons, wrapping rather than clipping",
      "Column headers are 40px-tall buttons; rows below scroll sideways",
      "Results is the selected tab in the bottom bar"
    ])
  end
end
