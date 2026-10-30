defmodule IxpipeApp.MainViewFuzzTest do
  # Random sequences of what a user can do next, with invariants checked
  # after every step. A failure prints the shrunk action list: pin it as a
  # plain test in main_view_test.exs. Raise the case count to hunt:
  # FUZZ_RUNS=2000 mix test test/ixpipe_app/main_view_fuzz_test.exs
  use ExUnit.Case, async: false
  use ExUnitProperties
  alias Baguette.Test
  alias IxpipeApp.UI
  alias IxpipeCore.Spec

  @fixtures Path.expand("../fixtures", __DIR__)
  @runs String.to_integer(System.get_env("FUZZ_RUNS", "40"))

  property "no sequence of clicks and drags breaks the main window" do
    check all(
            steps <-
              list_of({integer(0..1000), integer(-200..200), integer(-200..200)}, max_length: 25),
            max_runs: @runs
          ) do
      {window, pid, dir} = start()

      try do
        Enum.reduce(steps, [], fn {pick, dx, dy}, trail ->
          actions = UI.actions(window)
          action = Enum.at(actions, rem(pick, length(actions)))
          trail = [action | trail]

          case action do
            {:click, label} -> Test.click(window, label)
            {:drag, label} -> Test.drag(window, label, dx, dy)
          end

          assert_invariants(window, pid, dir, Enum.reverse(trail))
          trail
        end)
      after
        stop_supervised!({IxpipeApp.MainView, window})
        File.rm_rf!(dir)
      end
    end
  end

  defp start do
    dir = Path.join(System.tmp_dir!(), "ixpipe-fuzz-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "sales.yaml"), """
    name: sales
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
      - {id: sorted, tool: sort, position: {x: 260, y: 40}, inputs: {in: orders}, config: {by: [amount]}}
    """)

    window = System.unique_integer([:positive])

    pid =
      start_supervised!(
        {IxpipeApp.MainView, window: window, theme: IxpipeApp.Theme, args: [dir: dir]}
      )

    {window, pid, dir}
  end

  defp assert_invariants(window, pid, dir, trail) do
    assert Process.alive?(pid), "view died after #{inspect(trail)}"
    assert UI.unresolved_colours(window) == [], "unresolved colours after #{inspect(trail)}"
    assert UI.actions(window) != [], "nothing left to do after #{inspect(trail)}"

    %{assigns: assigns} = :sys.get_state(pid)

    if spec = assigns.spec do
      ids = Enum.map(spec.nodes, & &1.id)
      assert ids == Enum.uniq(ids), "duplicate ids after #{inspect(trail)}"

      for node <- spec.nodes,
          {_port, from} <- node.inputs,
          do: assert(from in ids, "dangling edge #{from} after #{inspect(trail)}")

      assert {:ok, ^spec} = spec |> Spec.to_yaml() |> Spec.decode(),
             "YAML does not round-trip after #{inspect(trail)}"

      assert String.starts_with?(assigns.path, dir)
    end
  end
end
