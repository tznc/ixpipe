defmodule IxpipeApp.OutputsViewTest do
  # Tools with several outputs on the canvas: a connector per output, wires
  # from a named output, counts per output and a switcher in Results.
  use ExUnit.Case, async: false
  alias Baguette.Test
  alias IxpipeCore.Spec

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-outputs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "sales.yaml"), """
    name: sales
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
      - {id: big, tool: filter, position: {x: 280, y: 40}, inputs: {in: orders}, config: {expr: "amount > 20"}}
    """)

    window = System.unique_integer([:positive])

    start_supervised!(
      {IxpipeApp.MainView,
       window: window,
       theme: IxpipeApp.Theme,
       args: [dir: dir, path: Path.join(dir, "sales.yaml")]}
    )

    %{w: window, dir: dir}
  end

  test "a tool with several outputs has a connector for each", %{w: w} do
    assert [_] = Test.find_all(w, "Connect from orders")
    assert [_] = Test.find_all(w, "Connect from big true")
    assert [_] = Test.find_all(w, "Connect from big false")
  end

  test "wiring from a named output", %{w: w, dir: dir} do
    Test.click(w, "Add sort")
    Test.click(w, "Connect from big false")
    Test.click(w, "Connect to sort_1 in")
    Test.click(w, "Save workflow")

    {:ok, spec} = dir |> Path.join("sales.yaml") |> File.read!() |> Spec.decode()
    assert Enum.find(spec.nodes, &(&1.id == "sort_1")).inputs == %{"in" => "big.false"}
  end

  test "after a run, each output shows its count, and Results switches between them", %{w: w} do
    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "true · 1 row"
    assert Test.text(w) =~ "false · 1 row"

    Test.click(w, "Select big")
    assert Test.text(w) =~ "big.true · 1 row"
    assert Test.text(w) =~ "50"

    Test.click(w, "Show false output")
    assert Test.text(w) =~ "big.false · 1 row"
    refute Test.text(w) =~ "50"
  end
end
