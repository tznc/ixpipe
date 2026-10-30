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
    workflow =
      Path.join(System.tmp_dir!(), "ixpipe-e2e-#{System.unique_integer([:positive])}.yaml")

    File.write!(workflow, """
    name: e2e
    nodes:
      - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
    """)

    System.put_env("IXPIPE_WORKFLOW", workflow)
    app = Playwright.start_app!(@app, port: 9335)

    on_exit(fn ->
      Playwright.stop_app(app)
      System.delete_env("IXPIPE_WORKFLOW")
      File.rm(workflow)
    end)

    %{page: Playwright.connect!(app)}
  end

  test "opens the workflow and runs it", %{page: page} do
    assert :ok = Playwright.await_text(page, "orders")
    Playwright.click(page, "Run")
    assert :ok = Playwright.await_text(page, "Run succeeded")
    assert :ok = Playwright.await_text(page, "2 rows")
  end
end
