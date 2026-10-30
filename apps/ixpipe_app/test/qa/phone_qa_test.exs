defmodule IxpipeApp.QA.PhoneTest do
  # Screenshot QA at a phone's size (390 x 844, portrait): the compact
  # header, the scrolling ribbon and the Canvas / Properties / Results panes.
  use ExUnit.Case, async: false
  alias Baguette.Playwright
  alias IxpipeApp.QA

  @moduletag :qa

  setup do
    qa = QA.launch!(open: "sales.yaml")
    on_exit(fn -> QA.stop(qa) end)
    assert :ok = Playwright.await_text(qa.page, "customers")
    :ok = Playwright.resize(qa.page, 390, 844)
    assert :ok = Playwright.await(qa.page, role: "tab", name: "Show canvas")
    qa
  end

  test "the canvas takes the full width", %{page: page} do
    QA.capture(page, "phone-01-canvas", [
      "A compact header: 'Workflows / sales.yaml' over 'sales', icon-only Save (outlined) and Run (teal) on the right, nothing clipped",
      "The ribbon's tabs fit or scroll in one row; the canvas fills the width with no side panel",
      "A tab bar across the bottom: Canvas (teal tint, selected), Properties, Results"
    ])
  end

  test "the ribbon's commands scroll sideways", %{page: page} do
    Playwright.click(page, "In/Out tab")
    assert :ok = Playwright.await(page, role: "button", name: "Add input_csv")

    QA.capture(page, "phone-02-ribbon", [
      "In/Out is the selected ribbon tab; its Input commands are tall (40px) buttons with icons",
      "Commands that do not fit run off the right edge (the row scrolls) rather than wrapping or squashing"
    ])
  end

  test "selecting a tool shows its properties", %{page: page} do
    Playwright.click(page, "Select joined")
    assert :ok = Playwright.await(page, role: "textbox", name: "Join on")

    QA.capture(page, "phone-03-properties", [
      "The Properties pane fills the width: 'joined', caption 'Join', a full-width 'Join on' input",
      "'Join type' options are 40px tall buttons; Properties is the selected tab in the bottom bar"
    ])
  end

  test "a run shows the selected tool's rows", %{page: page} do
    Playwright.click(page, "Select sorted")
    assert :ok = Playwright.await(page, role: "tab", name: "Show results")
    Playwright.click(page, "Run workflow")
    assert :ok = Playwright.await_text(page, "Run succeeded")

    QA.capture(page, "phone-04-results", [
      "The Results pane fills the width: 'sorted · 3 rows' and a grid of name and total",
      "A green 'Run succeeded' callout over the bottom of the pane, inset 12px each side, above the tab bar",
      "Results is the selected tab in the bottom bar"
    ])
  end

  test "the home screen fits", %{page: page} do
    Playwright.click(page, "Workflows")
    assert :ok = Playwright.await_text(page, "scratch.yaml")

    QA.capture(page, "phone-05-home", [
      "'Workflows' title and a teal 'New workflow' button on one row, neither clipped",
      "sales.yaml, scratch.yaml and split.yaml as rows with their times on the right"
    ])
  end
end
