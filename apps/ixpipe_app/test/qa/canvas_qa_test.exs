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
        "A 'Workflows' heading with a 'New workflow' button on the right",
        "sales.yaml and scratch.yaml listed as full-width rows",
        "Light theme: white background, dark text, blue primary button"
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
        "Six node cards, none overlapping, inside the canvas area",
        "Lines join orders and customers to joined, then joined to totals to sorted to out",
        "The tool palette on the left lists all eight tools"
      ])
    end

    test "run shows row counts on every node", %{page: page} do
      Playwright.click(page, "Run")
      assert :ok = Playwright.await_text(page, "Run succeeded")

      QA.capture(page, "canvas-02-run", [
        "The toolbar status reads 'Run succeeded'",
        "Every node card shows a row count: orders 4, customers 3, joined 4, totals 3, sorted 3, out 3"
      ])
    end

    test "connecting highlights the source node", %{page: page} do
      Playwright.click(page, "Connect from orders")
      assert :ok = Playwright.await_text(page, "Connecting from orders")

      QA.capture(page, "canvas-03-connecting", [
        "The orders card has a blue border; no other card does",
        "The toolbar status reads 'Connecting from orders'"
      ])
    end
  end
end
