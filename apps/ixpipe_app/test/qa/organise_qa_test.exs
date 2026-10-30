defmodule IxpipeApp.QA.OrganiseTest do
  # Screenshot QA of organising the canvas: containers (expanded, collapsed,
  # disabled), comments, annotations and disabled tools.
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

  defp contain_joined(page) do
    Playwright.click(page, "Select joined")
    Playwright.click(page, "Add container")
    assert :ok = Playwright.await(page, role: "textbox", name: "Title")
    Playwright.fill(page, "Title", "Combine")
    assert :ok = Playwright.await_text(page, "Container · 1 tool")
  end

  test "a container around a tool", %{page: page} do
    contain_joined(page)

    QA.capture(page, "organise-01-container", [
      "A grey box with a teal border around the joined card, titled 'Combine' with a chevron, behind the card",
      "The right panel shows 'Combine', 'Container · 1 tool', a Title input, Collapse and Disable buttons and two red Remove buttons",
      "The Home ribbon tab has an Organise group with Container and Comment commands, each with an icon"
    ])
  end

  test "a collapsed container", %{page: page} do
    contain_joined(page)
    Playwright.click(page, "Collapse container_1")
    assert :ok = Playwright.await(page, role: "button", name: "Expand container_1")

    QA.capture(page, "organise-02-collapsed", [
      "The joined card is gone; a short 'Combine' title bar with a right-pointing chevron sits where its box was",
      "Wires from orders and customers end at the bar's left edge; the wire to totals leaves its right edge"
    ])
  end

  test "a disabled tool is skipped with what follows", %{page: page} do
    Playwright.click(page, "Select totals")
    Playwright.click(page, "Disable tool")
    assert :ok = Playwright.await(page, role: "button", name: "Enable tool")
    Playwright.click(page, "Run workflow")
    assert :ok = Playwright.await_text(page, "Run succeeded")

    QA.capture(page, "organise-03-disabled", [
      "The totals card is faded (40% opacity); sorted and out are not faded",
      "totals, sorted and out each show a grey 'Skipped' pill; orders, customers and joined show green row counts",
      "The callout says the run succeeded and that 3 tools were skipped"
    ])
  end

  test "a comment and an annotation", %{page: page} do
    Playwright.click(page, "Select sorted")
    Playwright.click(page, "Summarise settings")
    assert :ok = Playwright.await_text(page, "Sort by: total · Descending: true")
    Playwright.click(page, "Add comment")
    assert :ok = Playwright.await(page, role: "textbox", name: "Comment")
    Playwright.fill(page, "Comment", "Totals by customer, largest first")
    assert :ok = Playwright.await_text(page, "Totals by customer, largest first")

    QA.capture(page, "organise-04-comment", [
      "A caption 'Sort by: total · Descending: true' sits under the sorted card",
      "A grey comment box with a teal border reads 'Totals by customer, largest first', clear of the cards",
      "The right panel is titled 'Comment' with a Text input and a red 'Remove comment' button"
    ])
  end

  test "a container's properties on a phone", %{page: page} do
    contain_joined(page)
    :ok = Playwright.resize(page, 390, 844)
    assert :ok = Playwright.await(page, role: "tab", name: "Show properties")
    Playwright.click(page, "Show properties")
    assert :ok = Playwright.await(page, role: "textbox", name: "Title")

    QA.capture(page, "organise-05-phone", [
      "The Properties pane fills the width: 'Combine', a full-width Title input",
      "Collapse, Disable and the two Remove buttons are 40px tall and wrap rather than clip",
      "Properties is the selected tab in the bottom bar"
    ])
  end
end
