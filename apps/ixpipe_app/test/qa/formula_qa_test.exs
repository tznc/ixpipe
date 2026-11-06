defmodule IxpipeApp.QA.FormulaTest do
  # Screenshot QA of the formula tools (Multi-Row Formula, Multi-Field
  # Formula, DateTime) and the function reference in the properties panel.
  use ExUnit.Case, async: false
  alias Baguette.Playwright
  alias IxpipeApp.QA

  @moduletag :qa
  @orders Path.expand("fixtures/orders.csv", __DIR__)

  describe "function reference" do
    setup do
      qa = QA.launch!(open: "split.yaml")
      on_exit(fn -> QA.stop(qa) end)
      qa
    end

    test "a filter's condition gets the reference and completions", %{page: page} do
      Playwright.click(page, "Select big")
      assert :ok = Playwright.await(page, role: "textbox", name: "Search functions")

      QA.capture(page, "formula-01-reference", [
        "Under the Condition setting, a 'Functions' section: a search box and category buttons All (teal), String, Math, Date, Conditional, Conversion",
        "Each function shows its signature (upper(text)…) as a button, a description and an example with its result",
        "The panel scrolls; nothing overlaps or clips at the panel's right edge"
      ])

      Playwright.click(page, "Functions: date")
      Playwright.fill(page, "Condition", "amount > 20 AND date")
      assert :ok = Playwright.await(page, role: "button", name: "Complete date_diff")

      QA.capture(page, "formula-02-completions", [
        "Under the Condition input, a row of completion buttons with a function icon: date_diff, date_trunc, date_part",
        "The Date category is selected (teal) and only date functions are listed"
      ])

      Playwright.click(page, "Complete date_diff")
      Process.sleep(300)
      assert Playwright.input_value(page, "Condition") == "amount > 20 AND date_diff("
    end
  end

  describe "formula tools" do
    setup do
      qa = QA.launch!(open: "scratch.yaml")
      on_exit(fn -> QA.stop(qa) end)
      qa
    end

    test "the Preparation tab's Formula group", %{page: page} do
      Playwright.click(page, role: "tab", name: "Preparation tab")
      assert :ok = Playwright.await(page, role: "button", name: "Add multi_row_formula")

      QA.capture(page, "formula-03-ribbon", [
        "Preparation tab: groups Columns (Select, Data cleansing), Formula (Formula, Multi-row, Multi-field) and Rows",
        "Multi-row has a three-rows icon and Multi-field a four-columns icon; every command has one icon"
      ])
    end

    test "multi-row formula and DateTime run on orders", %{page: page} do
      Playwright.click(page, role: "tab", name: "In/Out tab")
      Playwright.click(page, "Add input_csv")
      Playwright.fill(page, "File", @orders)

      Playwright.click(page, role: "tab", name: "Preparation tab")
      Playwright.click(page, "Add multi_row_formula")
      Playwright.drag(page, "multi_row_formula_1", 210, -40)
      Playwright.click(page, "Connect from input_csv_1")
      Playwright.click(page, "Connect to multi_row_formula_1 in")
      Playwright.click(page, "Select multi_row_formula_1")
      Playwright.fill(page, "Column", "change")
      Playwright.fill(page, "Expression", "amount - [Row-1:amount]")
      Playwright.fill(page, "Group by", "customer_id")
      Playwright.click(page, "Rows out of range zero")

      Playwright.click(page, role: "tab", name: "Parse tab")
      Playwright.click(page, "Add date_time")
      Playwright.drag(page, "date_time_1", 410, 60)
      Playwright.click(page, "Connect from multi_row_formula_1")
      Playwright.click(page, "Connect to date_time_1 in")
      Playwright.click(page, "Select date_time_1")
      Playwright.fill(page, "Column", "id")
      Playwright.fill(page, "Format", "dd/MM/yyyy")

      Playwright.click(page, "Run workflow")
      assert :ok = Playwright.await_text(page, "Run succeeded")
      Playwright.click(page, "Select multi_row_formula_1")
      assert :ok = Playwright.await_text(page, "multi_row_formula_1 · 4 rows")

      QA.capture(page, "formula-04-multi-row", [
        "Three cards wired left to right: input_csv_1, multi_row_formula_1, date_time_1 (out and failed connectors, pills)",
        "Results: id, customer_id, amount, change; change is 50, 5, -20, 12 (customer 10's second order is 30 - 50)",
        "Properties: Column 'change', Expression, Group by customer_id, 'zero' highlighted, then the Functions reference"
      ])

      Playwright.click(page, "Select date_time_1")
      Playwright.click(page, "Show failed output")
      assert :ok = Playwright.await_text(page, "date_time_1.failed · 4 rows")

      QA.capture(page, "formula-05-date-time", [
        "date_time_1's card shows pills 'out · 4 rows' and 'failed · 4 rows'",
        "Results shows date_time_1.failed with four rows; the 'failed' switch is highlighted",
        "Properties: Column, Convert (parse highlighted), Format, Output column; no Functions reference"
      ])
    end
  end
end
