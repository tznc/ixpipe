defmodule IxpipeApp.RunMessagesViewTest do
  # A run reports per-tool messages (Messages, beside Results), badges the
  # cards that warned, failed or were skipped, sums up in the run callout,
  # and keeps the results of the tools that ran when another failed.
  use ExUnit.Case, async: false
  alias Baguette.Test
  alias IxpipeApp.UI

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-msgs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "partial.yaml"), """
    name: partial
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
      - id: bad
        tool: filter
        position: {x: 300, y: 40}
        inputs: {in: orders}
        config: {expr: "nope > 1"}
      - {id: after, tool: sort, position: {x: 560, y: 40}, inputs: {in: bad.true}, config: {by: [id]}}
      - {id: fine, tool: sort, position: {x: 300, y: 260}, inputs: {in: orders}, config: {by: [amount]}}
    """)

    File.write!(Path.join(dir, "warns.yaml"), """
    name: warns
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
      - id: calc
        tool: formula
        position: {x: 300, y: 40}
        inputs: {in: orders}
        config: {formulas: [{as: blank, expr: "amount * NULL"}]}
    """)

    %{dir: dir, window: System.unique_integer([:positive])}
  end

  defp start(%{dir: dir, window: window}, file) do
    start_supervised!(
      {IxpipeApp.MainView,
       window: window, theme: IxpipeApp.Theme, args: [dir: dir, path: Path.join(dir, file)]}
    )

    Test.resize(window, 1200, 800)
    window
  end

  defp badges(w, tone) do
    for %{"a" => %{"data-badge" => ^tone}} = el <- elements(Test.tree(w)), do: text(el)
  end

  defp elements(%{"c" => children} = el), do: [el | Enum.flat_map(children, &elements/1)]
  defp elements(_), do: []
  defp text(text) when is_binary(text), do: text
  defp text(%{"c" => children}), do: Enum.map_join(children, "", &text/1)

  test "a partial failure says where, and keeps the other tools' results", ctx do
    w = start(ctx, "partial.yaml")
    Test.click(w, "Run workflow")

    text = Test.text(w)
    assert text =~ "Failed at bad."
    assert text =~ ~s(Column "nope" isn't in the input.)
    assert "Error" in badges(w, "danger")
    assert "Skipped" in badges(w, "neutral")

    Test.click(w, "Select fine")
    assert Test.text(w) =~ "fine · 2 rows"
  end

  test "a run with warnings says how many and badges the tool", ctx do
    w = start(ctx, "warns.yaml")
    Test.click(w, "Run workflow")

    assert Test.text(w) =~ "Ran with 1 warning"
    assert "1 warning" in badges(w, "warning")
  end

  test "Messages lists every message by tool, filters by level, and selects a tool", ctx do
    w = start(ctx, "partial.yaml")
    Test.click(w, "Run workflow")
    Test.click(w, "Messages tab")

    text = Test.text(w)
    assert UI.find(w, "Messages") != []
    [panel] = UI.find(w, "Messages")
    # Tools in the workflow's order, not the order they ran in.
    assert text(panel) =~ ~r/orders.*bad.*after.*fine/s
    assert text =~ "Didn't run because bad failed."
    assert text =~ "2 rows in"

    Test.click(w, "Show errors")
    text = Test.text(w)
    assert text =~ ~s(Column "nope" isn't in the input.)
    refute text =~ "Didn't run because"

    {:click, label} =
      Enum.find(UI.actions(w), &match?({:click, "bad: Column" <> _}, &1))

    Test.click(w, label)
    [config] = UI.find(w, "Configuration")
    assert text(config) =~ "bad"
  end

  test "Messages lists tools in the workflow's order, not the order they ran in", ctx do
    File.write!(Path.join(ctx.dir, "two.yaml"), """
    nodes:
      - {id: zeta, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
      - {id: alpha, tool: input_csv, position: {x: 40, y: 240}, config: {path: #{@fixtures}/orders.csv}}
    """)

    w = start(ctx, "two.yaml")
    Test.click(w, "Run workflow")
    Test.click(w, "Messages tab")
    [panel] = UI.find(w, "Messages")
    assert text(panel) =~ ~r/zeta.*alpha/s
  end

  test "Messages before a run has an empty state", ctx do
    w = start(ctx, "warns.yaml")
    Test.click(w, "Messages tab")
    assert Test.text(w) =~ "No messages yet"
  end

  test "on a phone, Messages is a pane", ctx do
    w = start(ctx, "warns.yaml")
    Test.resize(w, 390, 844)
    Test.click(w, "Run workflow")
    Test.click(w, "Show messages")
    assert UI.find(w, "Messages") != []
    assert Test.text(w) =~ ~s(Formula "blank" is NULL on every row.)
  end
end
