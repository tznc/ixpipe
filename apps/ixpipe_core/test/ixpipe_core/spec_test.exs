defmodule IxpipeCore.SpecTest do
  use ExUnit.Case, async: true
  alias IxpipeCore.Spec

  test "parses nodes, tools, inputs and config from YAML" do
    yaml = """
    name: sales
    nodes:
      - id: orders
        tool: input_csv
        config: {path: orders.csv}
      - id: sorted
        tool: sort
        inputs: {in: orders}
        config: {by: [amount]}
    """

    assert {:ok, %Spec{name: "sales", nodes: [orders, sorted]}} = Spec.parse(yaml)
    assert %Spec.Node{id: "orders", tool: IxpipeCore.Tools.InputCsv, inputs: %{}} = orders
    assert orders.config == %{"path" => "orders.csv"}
    assert %Spec.Node{tool: IxpipeCore.Tools.Sort, inputs: %{"in" => "orders"}} = sorted
  end

  test "rejects invalid YAML" do
    assert {:error, {:invalid_yaml, _}} = Spec.parse("nodes: [")
  end

  test "rejects unknown tools" do
    assert {:error, {:unknown_tool, "orders", "nope"}} =
             Spec.parse("nodes: [{id: orders, tool: nope}]")
  end

  test "rejects duplicate node ids" do
    assert {:error, {:duplicate_id, "a"}} =
             Spec.parse("nodes: [{id: a, tool: input_csv}, {id: a, tool: input_csv}]")
  end

  test "rejects inputs that reference missing nodes" do
    yaml = "nodes: [{id: s, tool: sort, inputs: {in: ghost}}]"
    assert {:error, {:unknown_input, "s", "ghost"}} = Spec.parse(yaml)
  end

  test "rejects missing or unknown ports" do
    assert {:error, {:bad_ports, "s", expected: ["in"], got: []}} =
             Spec.parse("nodes: [{id: s, tool: sort}]")

    yaml = "nodes: [{id: a, tool: input_csv}, {id: s, tool: sort, inputs: {in: a, x: a}}]"
    assert {:error, {:bad_ports, "s", expected: ["in"], got: ["in", "x"]}} = Spec.parse(yaml)
  end

  test "rejects cycles" do
    yaml = """
    nodes:
      - {id: a, tool: sort, inputs: {in: b}}
      - {id: b, tool: sort, inputs: {in: a}}
    """

    assert {:error, {:cycle, ids}} = Spec.parse(yaml)
    assert Enum.sort(ids) == ["a", "b"]
  end

  test "format_error/1 describes each error" do
    assert Spec.format_error({:unknown_tool, "a", "nope"}) == ~s(a: unknown tool "nope")
    assert Spec.format_error({:duplicate_id, "a"}) == "duplicate node id a"
    assert Spec.format_error({:unknown_input, "s", "x"}) == "s: input x is not a node"

    assert Spec.format_error({:bad_ports, "s", expected: ["in"], got: []}) ==
             "s: expects inputs [in], got []"

    assert Spec.format_error({:cycle, ["a", "b"]}) == "cycle: a -> b"
    assert Spec.format_error({:invalid_yaml, :boom}) =~ "invalid YAML"
  end
end
