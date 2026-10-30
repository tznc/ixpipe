defmodule IxpipeApp.WorkflowViewTest do
  use ExUnit.Case, async: false
  alias Baguette.Test

  @fixtures Path.expand("../fixtures", __DIR__)
  @window 1

  defp start_view(yaml) do
    path = Path.join(System.tmp_dir!(), "ixpipe-#{System.unique_integer([:positive])}.yaml")
    File.write!(path, yaml)
    on_exit(fn -> File.rm(path) end)
    start_supervised!({IxpipeApp.WorkflowView, window: @window, args: [path: path]})
  end

  test "shows the workflow's nodes and their tools" do
    start_view("""
    name: sales
    nodes:
      - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
      - {id: sorted, tool: sort, inputs: {in: orders}, config: {by: [amount]}}
    """)

    text = Test.text(@window)
    assert text =~ "sales"
    assert text =~ "orders"
    assert text =~ "input_csv"
    assert text =~ "sorted"
  end

  test "Run runs the workflow and reports each node's row count" do
    start_view("""
    nodes:
      - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
    """)

    Test.click(@window, "Run")
    assert Test.text(@window) =~ "Run succeeded"
    assert Test.text(@window) =~ "2 rows"
  end

  test "Run reports the failing node" do
    start_view("nodes: [{id: orders, tool: input_csv, config: {path: /nope.csv}}]")

    Test.click(@window, "Run")
    assert Test.text(@window) =~ "orders failed"
  end

  test "shows why a workflow failed to load" do
    start_view("nodes: [{id: a, tool: nope}]")
    assert Test.text(@window) =~ "unknown tool"
  end
end
