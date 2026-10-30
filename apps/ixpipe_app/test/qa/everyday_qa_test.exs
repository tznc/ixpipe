defmodule IxpipeApp.QA.EverydayToolsTest do
  # Screenshot QA of the everyday tools: Record ID, Running Total, Join
  # Multiple (optional ports) and Generate Rows (a source when its input is
  # unconnected), and the ribbon groups that hold them.
  use ExUnit.Case, async: false
  alias Baguette.Playwright
  alias IxpipeApp.QA

  @moduletag :qa

  setup do
    fixtures = QA.fixtures()

    yaml = """
    name: everyday
    nodes:
      - {id: orders, tool: input_csv, position: {x: 20, y: 30}, config: {path: #{fixtures}/orders.csv}}
      - {id: customers, tool: input_csv, position: {x: 20, y: 210}, config: {path: #{fixtures}/customers.csv}}
      - {id: ids, tool: record_id, position: {x: 240, y: 30}, inputs: {in: orders}}
      - {id: totals, tool: running_total, position: {x: 460, y: 30}, inputs: {in: ids}, config: {columns: [amount]}}
      - id: joined
        tool: join_multiple
        position: {x: 240, y: 210}
        inputs: {in1: orders, in2: customers}
        config: {on: [customer_id]}
      - {id: days, tool: generate_rows, position: {x: 460, y: 210}, config: {name: n, init: "1", condition: "n <= 5", loop: "n + 1"}}
    """

    qa = QA.launch!(open: "everyday.yaml", workflows: [{"everyday.yaml", yaml}])
    on_exit(fn -> QA.stop(qa) end)
    qa
  end

  test "a run through the new tools, with a running total's rows", %{page: page} do
    Playwright.click(page, "Run workflow")
    assert :ok = Playwright.await_text(page, "Run succeeded")
    Playwright.click(page, "Select totals")
    assert :ok = Playwright.await_text(page, "totals · 4 rows")

    QA.capture(page, "everyday-01-run", [
      "Cards: orders, customers, ids (Record ID), totals (Running total), joined (Join multiple, In ports in1 to in4, two wired), days (Generate rows, no wire in) with green row pills: ids 4, totals 4, joined 4, days 5",
      "Results shows totals: RecordID 1 to 4 first, then id, customer_id, amount, and RunningTotal_amount 50, 55, 85, 97",
      "Nothing overlaps; wires into joined arrive at in1 and in2"
    ])
  end

  test "Join multiple's settings", %{page: page} do
    Playwright.click(page, "Select joined")
    assert :ok = Playwright.await(page, role: "textbox", name: "Join on")

    QA.capture(page, "everyday-02-join-multiple", [
      "The right panel is titled 'joined', caption 'Join multiple'",
      "'Join on' reads customer_id; 'Join type' offers outer and inner",
      "The joined card has a teal border and four In ports: in1, in2, in3, in4"
    ])
  end

  test "the Join tab's groups", %{page: page} do
    Playwright.click(page, role: "tab", name: "Join tab")
    assert :ok = Playwright.await(page, role: "button", name: "Add fuzzy_match")

    QA.capture(page, "everyday-03-ribbon-join", [
      "Join tab selected: Combine (Join, Union, Join multiple, Append fields) and Match (Find replace, Fuzzy match)",
      "Each command has its own icon (merge, layers, combine, rows-insert, replace, scan-search) before its label; group names are captions beneath",
      "Nothing wraps or clips"
    ])
  end
end
