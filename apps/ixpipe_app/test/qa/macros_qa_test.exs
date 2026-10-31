defmodule IxpipeApp.QA.MacrosTest do
  # Screenshot QA of macros: the home's macro badge, a macro node, its run,
  # opening it, and the Macros ribbon tab (see .claude/skills/app-qa).
  use ExUnit.Case, async: false
  alias Baguette.Playwright
  alias IxpipeApp.QA

  @moduletag :qa

  @fixtures Path.expand("fixtures", __DIR__)

  @big """
  name: Big orders
  macro:
    parameters: [{name: threshold, type: integer, label: Threshold, default: 10}]
  nodes:
    - {id: rows, tool: macro_input, position: {x: 20, y: 60}, config: {columns: [amount], path: #{@fixtures}/orders.csv}}
    - {id: f, tool: filter, position: {x: 240, y: 60}, inputs: {in: rows}, config: {expr: "amount > {{threshold}}"}}
    - {id: big, tool: macro_output, position: {x: 460, y: 60}, inputs: {in: f.true}}
  """

  @uses """
  name: uses
  nodes:
    - {id: orders, tool: input_csv, position: {x: 20, y: 60}, config: {path: #{@fixtures}/orders.csv}}
    - {id: m, tool: macro, position: {x: 240, y: 60}, inputs: {rows: orders}, config: {path: big.yaml, threshold: 20}}
    - {id: sorted, tool: sort, position: {x: 460, y: 60}, inputs: {in: m}, config: {by: [amount]}}
  """

  @files %{"big.yaml" => @big, "uses.yaml" => @uses}

  describe "home" do
    setup do
      qa = QA.launch!(files: @files)
      on_exit(fn -> QA.stop(qa) end)
      qa
    end

    test "marks macro files", %{page: page} do
      assert :ok = Playwright.await_text(page, "uses.yaml")

      QA.capture(page, "macros-01-home", [
        "big.yaml has a grey 'Macro' pill right after its name; no other file has one",
        "The rows stay aligned: names left, relative times right"
      ])
    end
  end

  describe "canvas" do
    setup do
      qa = QA.launch!(files: @files, open: "uses.yaml")
      on_exit(fn -> QA.stop(qa) end)
      qa
    end

    test "a macro node shows its macro, ports and parameters", %{page: page} do
      Playwright.click(page, "Select m")
      assert :ok = Playwright.await(page, role: "textbox", name: "Threshold")
      assert Playwright.input_value(page, "Threshold") == "20"

      QA.capture(page, "macros-02-node", [
        "The m card's caption reads 'Macro · Big orders', with an In row 'rows' and an Out row",
        "The right panel shows an 'Open macro' button above a 'Macro' path field (big.yaml) and 'Threshold' (20)",
        "Wires run orders -> m -> sorted"
      ])
    end

    test "runs, and opens the macro with a breadcrumb back", %{page: page} do
      Playwright.click(page, "Run workflow")
      assert :ok = Playwright.await_text(page, "Run succeeded")

      QA.capture(page, "macros-03-run", [
        "A green 'Run succeeded' callout bottom-left",
        "orders shows '4 rows'; m and sorted each show '2 rows'"
      ])

      Playwright.click(page, "Select m")
      Playwright.click(page, "Open macro")
      assert :ok = Playwright.await_text(page, "Big orders")

      QA.capture(page, "macros-04-open", [
        "Breadcrumb 'Workflows / uses.yaml / big.yaml' over the title 'Big orders'",
        "Three cards: rows (Macro input), f (Filter), big (Macro output), wired left to right"
      ])

      Playwright.click(page, "uses.yaml")
      assert :ok = Playwright.await(page, role: "button", name: "Open macro")
    end

    test "the Macros tab", %{page: page} do
      Playwright.click(page, role: "tab", name: "Macros tab")
      assert :ok = Playwright.await_text(page, "Use a macro…")

      QA.capture(page, "macros-05-ribbon", [
        "The Macros tab is selected; one group captioned 'Macros' beneath",
        "Three quiet commands with icons: 'Macro input', 'Macro output', 'Use a macro…'"
      ])
    end
  end
end
