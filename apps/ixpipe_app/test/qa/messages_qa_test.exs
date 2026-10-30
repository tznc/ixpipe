defmodule IxpipeApp.QA.MessagesTest do
  # Screenshot QA of a run's messages: a partial failure (a join on a
  # column that isn't there) beside a branch that warns, on a desktop
  # window and a phone's. Captures land in test/qa/.shots.
  use ExUnit.Case, async: false
  alias Baguette.Playwright
  alias IxpipeApp.QA

  @moduletag :qa
  @fixtures Path.expand("fixtures", __DIR__)

  setup do
    qa = QA.launch!(open: "sales.yaml")
    on_exit(fn -> QA.stop(qa) end)

    File.write!(Path.join(qa.home, "partial.yaml"), """
    name: partial
    nodes:
      - {id: orders, tool: input_csv, position: {x: 20, y: 30}, config: {path: #{@fixtures}/orders.csv}}
      - {id: customers, tool: input_csv, position: {x: 20, y: 230}, config: {path: #{@fixtures}/customers.csv}}
      - id: joined
        tool: join
        position: {x: 260, y: 130}
        inputs: {left: orders, right: customers}
        config: {on: [customer]}
      - id: totals
        tool: summarize
        position: {x: 500, y: 130}
        inputs: {in: joined.joined}
        config: {group_by: [name], aggregates: [{column: amount, op: sum, as: total}]}
      - id: taxed
        tool: formula
        position: {x: 500, y: 330}
        inputs: {in: orders}
        config: {formulas: [{as: tax, expr: "amount * NULL"}]}
    """)

    assert :ok = Playwright.await_text(qa.page, "customers")
    Playwright.click(qa.page, "Workflows")
    Playwright.click(qa.page, "Open partial.yaml")
    assert :ok = Playwright.await_text(qa.page, "taxed")
    Playwright.click(qa.page, "Run workflow")
    assert :ok = Playwright.await_text(qa.page, "Failed at joined.")
    qa
  end

  test "a partial failure badges the cards and keeps the rest", %{page: page} do
    Playwright.click(page, "Select taxed")
    assert :ok = Playwright.await_text(page, "taxed · 4 rows")

    QA.capture(page, "messages-01-partial", [
      "joined has a red-tinted 'Error' pill, totals a grey 'Skipped' pill, taxed an amber '1 warning' pill; orders and customers green row pills",
      "A red-tinted callout bottom-left titled 'Failed at joined.' explaining the missing column and what to do",
      "Results shows taxed's 4 rows with an empty tax column; the layout did not move"
    ])
  end

  test "Messages lists every tool's messages and filters them", %{page: page} do
    Playwright.click(page, role: "tab", name: "Messages tab")
    assert :ok = Playwright.await(page, role: "button", name: "Show errors")

    QA.capture(page, "messages-02-panel", [
      "Under the canvas, the Messages tab is selected beside Results; filter buttons All, Errors, Warnings, Info with counts",
      "Messages grouped under each tool id with its tool name in a caption, in workflow order",
      "Each message has a tinted pill (Error red, Warning amber, Info grey) then its sentence, left-aligned"
    ])

    Playwright.click(page, "Show warnings")
    assert :ok = Playwright.await_text(page, "Warnings 1")

    QA.capture(page, "messages-03-warnings", [
      "Only the taxed group shows, with one amber Warning about the formula being NULL on every row",
      "The Warnings filter has the teal border and tint; the others do not"
    ])
  end

  test "on a phone, Messages is a pane", %{page: page} do
    :ok = Playwright.resize(page, 390, 844)
    Playwright.click(page, role: "tab", name: "Show messages")
    assert :ok = Playwright.await(page, role: "button", name: "Show errors")

    QA.capture(page, "messages-04-phone", [
      "The Messages pane fills the width, titled 'Messages', with 40px filter buttons that wrap",
      "Message sentences wrap within the width; nothing is clipped",
      "Messages is the selected tab in the bottom bar of four: Canvas, Properties, Results, Messages"
    ])
  end
end
