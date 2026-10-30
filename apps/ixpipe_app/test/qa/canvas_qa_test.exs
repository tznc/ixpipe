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
        "sales.yaml and scratch.yaml listed as rows, each with a muted relative time on the right",
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
        "A breadcrumb 'Workflows / sales.yaml' above the title 'sales'; Save workflow outlined, Run workflow teal",
        "Six node cards, none overlapping, each with a red-outlined Remove button; lines join them",
        "A light sidebar labelled 'Tools' lists all eight tools in sentence case (Input CSV, ...)"
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
  end
end
