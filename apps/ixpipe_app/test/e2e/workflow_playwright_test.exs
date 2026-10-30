defmodule IxpipeApp.E2E.WorkflowPlaywrightTest do
  # The ixpipe release, driven through gpui-playwright. Build it first:
  #
  #     BAGUETTE_HOST_FEATURES=playwright MIX_ENV=prod mix release ixpipe --overwrite
  #
  # then run `mix test --only playwright` under a display (`xvfb-run -a`).
  use ExUnit.Case, async: false
  alias Baguette.Playwright

  @moduletag :playwright

  @app Path.expand("../../../../_build/prod/rel/ixpipe/bin/ixpipe_app", __DIR__)
  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    home = Path.join(System.tmp_dir!(), "ixpipe-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    workflow = Path.join(home, "e2e.yaml")

    File.write!(workflow, """
    name: e2e
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
    """)

    System.put_env("IXPIPE_HOME", home)
    System.put_env("IXPIPE_WORKFLOW", workflow)
    app = Playwright.start_app!(@app, port: 9335)

    on_exit(fn ->
      Playwright.stop_app(app)
      System.delete_env("IXPIPE_HOME")
      System.delete_env("IXPIPE_WORKFLOW")
      File.rm_rf!(home)
    end)

    %{page: Playwright.connect!(app), workflow: workflow}
  end

  test "opens the workflow and runs it", %{page: page} do
    assert :ok = Playwright.await_text(page, "orders")
    Playwright.click(page, "Run workflow")
    assert :ok = Playwright.await_text(page, "Run succeeded")
    assert :ok = Playwright.await_text(page, "2 rows")
  end

  test "builds and saves a workflow on the canvas", %{page: page, workflow: workflow} do
    assert :ok = Playwright.await_text(page, "orders")
    Playwright.click(page, role: "tab", name: "Preparation tab")
    Playwright.click(page, "Add sort")
    assert :ok = Playwright.await(page, role: "button", name: "Select sort_1")

    Playwright.drag(page, "sort_1", 220, 0)
    Playwright.click(page, "Connect from orders")
    Playwright.click(page, "Connect to sort_1 in")
    Playwright.click(page, "Save workflow")
    assert :ok = Playwright.await_text(page, "Saved e2e.yaml")

    File.write!(Path.join(System.tmp_dir!(), "ixpipe-canvas.png"), Playwright.screenshot(page))

    {:ok, spec} = workflow |> File.read!() |> IxpipeCore.Spec.decode()

    assert [_orders, %{id: "sort_1", inputs: %{"in" => "orders"}, position: %{"x" => x}}] =
             spec.nodes

    assert_in_delta x, 290, 2
  end
end
