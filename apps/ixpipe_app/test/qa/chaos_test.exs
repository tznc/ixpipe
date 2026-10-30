defmodule IxpipeApp.QA.ChaosTest do
  # A seeded monkey on the real app: random buttons, drags and runs, with the
  # app process, the Playwright server and the app log checked after every
  # step. Replay a failure with its seed:
  #   QA_SEED=123 QA_STEPS=200 xvfb-run -a mix test --only chaos
  # A scroll is picked only while node cards (the canvas) are on screen.
  use ExUnit.Case, async: false
  alias Baguette.Playwright
  alias IxpipeApp.QA

  @moduletag :chaos
  @moduletag timeout: :infinity

  # QA_PHONE=1 walks the phone layout (390 x 844) instead.
  setup do
    qa = QA.launch!(open: "sales.yaml")
    on_exit(fn -> QA.stop(qa) end)

    if System.get_env("QA_PHONE") do
      assert :ok = Playwright.await_text(qa.page, "orders")
      :ok = Playwright.resize(qa.page, 390, 844)
      assert :ok = Playwright.await(qa.page, role: "tab", name: "Show canvas")
    end

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
      n when n <= 6 or nodes == [] ->
        {:click, Enum.random(buttons)}

      n when n <= 9 ->
        {:drag, Enum.random(nodes), :rand.uniform(301) - 151, :rand.uniform(301) - 151}

      _ ->
        {:scroll, :rand.uniform(401) - 201, :rand.uniform(401) - 201}
    end
  end

  # A user scrolls to a control before clicking it; the monkey clicks
  # whatever the window lists, so a control scrolled out of view (Playwright:
  # "not stable", "outside of the viewport", "scrolling into view") is
  # skipped, not a failure.
  defp perform(page, {:click, label}) do
    Playwright.click(%{page | opts: Keyword.put(page.opts, :timeout, 2_000)}, label)
  rescue
    error in RuntimeError ->
      unless error.message =~ ~r/not stable|outside of the viewport|scrolling into view/,
        do: reraise(error, __STACKTRACE__)

      :skipped
  end

  defp perform(page, {:drag, label, dx, dy}), do: Playwright.drag(page, label, dx, dy)
  defp perform(page, {:scroll, dx, dy}), do: Playwright.scroll(page, "Canvas", dx, dy)

  defp check!(app, page) do
    unless Playwright.alive?(app), do: raise("the app exited")
    _ = Playwright.aria_snapshot(page)
    log = Playwright.log(app)
    if log =~ "panicked", do: raise("the app panicked: #{log}")
  end
end
