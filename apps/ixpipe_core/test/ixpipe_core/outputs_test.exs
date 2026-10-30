defmodule IxpipeCore.OutputsTest do
  # Tools with several outputs, as in Alteryx: Filter's True/False and
  # Join's J/L/R. A wire names its source as `node` or `node.output`.
  use ExUnit.Case, async: true
  alias IxpipeCore.Table
  alias IxpipeCore.{Edit, Spec, Tools}

  @fixtures Path.expand("../fixtures", __DIR__)

  defp run!(yaml) do
    {:ok, spec} = Spec.parse(yaml)
    {:ok, results} = IxpipeCore.run(spec)
    results
  end

  defp ids(df), do: df |> Table.to_columns() |> Map.fetch!("id") |> Enum.sort()

  test "tools list their outputs; most have one" do
    assert Tools.outputs(Tools.Sort) == ["out"]
    assert Tools.outputs(Tools.Filter) == ["true", "false"]
    assert Tools.outputs(Tools.Join) == ["joined", "left", "right"]
  end

  test "filter sends matching rows to true and the rest to false" do
    results =
      run!("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - {id: big, tool: filter, inputs: {in: orders}, config: {expr: "amount > 20"}}
        - {id: yes, tool: sort, inputs: {in: big.true}, config: {by: [id]}}
        - {id: no, tool: sort, inputs: {in: big.false}, config: {by: [id]}}
        - {id: default, tool: sort, inputs: {in: big}, config: {by: [id]}}
      """)

    assert ids(results["yes"]) == [1, 3]
    assert ids(results["no"]) == [2, 4]
    assert ids(results["default"]) == [1, 3], "a bare node name means its first output"
    assert ids(results["big.true"]) == [1, 3]
    assert ids(results["big.false"]) == [2, 4]
    refute Map.has_key?(results, "big")
  end

  test "rows where the condition is null go to false" do
    {:ok, spec} =
      Spec.parse("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - {id: f, tool: filter, inputs: {in: orders}, config: {expr: "CASE WHEN id = 1 THEN NULL ELSE amount > 20 END"}}
      """)

    {:ok, results} = IxpipeCore.run(spec)
    assert ids(results["f.true"]) == [3]
    assert ids(results["f.false"]) == [1, 2, 4]
  end

  test "join sends matches to joined and unmatched rows to left and right" do
    File.write!(
      Path.join(System.tmp_dir!(), "ixpipe-few-customers.csv"),
      "customer_id,name\n10,Ada\n99,Zed\n"
    )

    results =
      run!("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - {id: customers, tool: input_csv, config: {path: #{System.tmp_dir!()}/ixpipe-few-customers.csv}}
        - {id: j, tool: join, inputs: {left: orders, right: customers}, config: {on: [customer_id]}}
      """)

    assert ids(results["j.joined"]) == [1, 3]
    assert ids(results["j.left"]) == [2, 4]
    assert Table.to_columns(results["j.right"])["name"] == ["Zed"]
    assert Table.columns(results["j.left"]) == ["id", "customer_id", "amount"]
  end

  test "a wire to an output a tool does not have is an error" do
    yaml = """
    nodes:
      - {id: orders, tool: input_csv, config: {path: x.csv}}
      - {id: f, tool: filter, inputs: {in: orders}, config: {expr: "1 = 1"}}
      - {id: s, tool: sort, inputs: {in: f.maybe}, config: {by: [id]}}
    """

    assert {:error, {:unknown_output, "s", "f.maybe"} = error} = Spec.parse(yaml)
    assert Spec.format_error(error) == "s: f has no output maybe"
  end

  test "node ids cannot contain dots" do
    assert {:error, {:bad_id, "a.b"} = error} = Spec.decode("nodes: [{id: a.b, tool: input_csv}]")
    assert Spec.format_error(error) == "a.b: an id can't contain a dot"
  end

  test "removing a node disconnects wires from any of its outputs" do
    {:ok, spec} =
      Spec.decode("""
      nodes:
        - {id: f, tool: filter}
        - {id: s, tool: sort, inputs: {in: f.false}}
      """)

    assert [%{id: "s", inputs: inputs}] = Edit.remove_node(spec, "f").nodes
    assert inputs == %{}
  end

  test "connect takes a node.output source" do
    {:ok, spec} = Spec.decode("nodes: [{id: f, tool: filter}, {id: s, tool: sort}]")
    spec = Edit.connect(spec, "f.false", "s", "in")
    assert Enum.find(spec.nodes, &(&1.id == "s")).inputs == %{"in" => "f.false"}
  end

  test "Spec.source/1 splits a wire's source" do
    assert Spec.source("f") == {"f", nil}
    assert Spec.source("f.false") == {"f", "false"}
  end
end
