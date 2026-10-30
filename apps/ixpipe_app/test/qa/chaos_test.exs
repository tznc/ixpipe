defmodule IxpipeApp.QA.ChaosTest do
  # A seeded monkey on the real app: random buttons, drags and runs, with the
  # app process, the Playwright server and the app log checked after every
  # step. Replay a failure with its seed:
  #   QA_SEED=123 QA_STEPS=200 xvfb-run -a mix test --only chaos
  use ExUnit.Case, async: false
  alias Baguette.Playwright
  alias IxpipeApp.QA

  @moduletag :chaos
  @moduletag timeout: :infinity

  setup do
    qa = QA.launch!(open: "sales.yaml")
    on_exit(fn -> QA.stop(qa) end)
    qa
  end

  test "survives a random walk", %{app: app, page: page} do
    seed = String.to_integer(System.get_env("QA_SEED", "#{:rand.uniform(1_000_000)}"))
    steps = String.to_integer(System.get_env("QA_STEPS", "80"))
    :rand.seed(:exsss, {seed, seed, seed})
    IO.puts("chaos seed #{seed}, #{steps} steps")
    assert :ok = Playwright.await_text(page, "orders")

    Enum.reduce(1..steps, [], fn step, trail ->
      action = pick(page)
      trail = [action | trail]

      try do
        perform(page, action)
        check!(app, page)
      rescue
        error ->
          shot = QA.capture(page, "chaos-#{seed}-failure", ["The state the failing step left"])

          flunk("""
          chaos seed #{seed} failed at step #{step}: #{Exception.message(error)}
          trail: #{inspect(Enum.reverse(trail))}
          screenshot: #{shot}
          log: #{Playwright.log(app)}
          """)
      end

      trail
    end)
  end

  defp pick(page) do
    buttons = Playwright.buttons(page)
    nodes = for "Remove " <> id <- buttons, do: id

    case :rand.uniform(10) do
      n when n <= 7 or nodes == [] -> {:click, Enum.random(buttons)}
      _ -> {:drag, Enum.random(nodes), :rand.uniform(301) - 151, :rand.uniform(301) - 151}
    end
  end

  defp perform(page, {:click, label}), do: Playwright.click(page, label)
  defp perform(page, {:drag, label, dx, dy}), do: Playwright.drag(page, label, dx, dy)

  defp check!(app, page) do
    unless Playwright.alive?(app), do: raise("the app exited")
    _ = Playwright.aria_snapshot(page)
    log = Playwright.log(app)
    if log =~ "panicked", do: raise("the app panicked: #{log}")
  end
end
