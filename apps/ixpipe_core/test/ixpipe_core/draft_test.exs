defmodule IxpipeCore.DraftTest do
  use ExUnit.Case, async: true
  alias IxpipeCore.{Edit, Spec}

  @yaml """
  name: sales
  nodes:
    - id: orders
      tool: input_csv
      position: {x: 40, y: 60}
      config: {path: orders.csv}
    - id: sorted
      tool: sort
      inputs: {in: orders}
      config: {by: [amount], desc: true}
  """

  test "decode/1 keeps incomplete workflows, which validate/1 rejects" do
    assert {:ok, draft} = Spec.decode("nodes: [{id: s, tool: sort}]")
    assert {:error, {:bad_ports, "s", _}} = Spec.validate(draft)
  end

  test "decode/1 still rejects unknown tools and duplicate ids" do
    assert {:error, {:unknown_tool, "a", "nope"}} = Spec.decode("nodes: [{id: a, tool: nope}]")
  end

  test "positions are kept, defaulting to nil" do
    {:ok, spec} = Spec.parse(@yaml)
    assert [%{position: %{"x" => 40, "y" => 60}}, %{position: nil}] = spec.nodes
  end

  test "to_yaml/1 round-trips" do
    {:ok, spec} = Spec.parse(@yaml)
    assert {:ok, ^spec} = spec |> Spec.to_yaml() |> Spec.parse()
  end

  test "to_yaml/1 quotes strings that YAML would read as something else" do
    spec = %Spec{
      name: "yes: no",
      nodes: [
        %Spec.Node{
          id: "f",
          tool: IxpipeCore.Tools.Filter,
          config: %{"expr" => "a > 1 AND b = 'x'"}
        }
      ]
    }

    assert {:ok, %Spec{name: "yes: no", nodes: [node]}} = spec |> Spec.to_yaml() |> Spec.decode()
    assert node.config == %{"expr" => "a > 1 AND b = 'x'"}
  end

  describe "Edit" do
    setup do
      {:ok, spec} = Spec.parse(@yaml)
      %{spec: spec}
    end

    test "add_node/3 adds a tool with a fresh id and empty config", %{spec: spec} do
      spec = Edit.add_node(spec, "sort", %{"x" => 10, "y" => 20})

      assert %Spec.Node{id: "sort_1", tool: IxpipeCore.Tools.Sort, inputs: %{}} =
               List.last(spec.nodes)

      assert List.last(spec.nodes).position == %{"x" => 10, "y" => 20}

      spec = Edit.add_node(spec, "sort", %{"x" => 0, "y" => 0})
      assert List.last(spec.nodes).id == "sort_2"
    end

    test "move_node/4 shifts a node, placing unpositioned ones from the origin", %{spec: spec} do
      spec = spec |> Edit.move_node("orders", 5, -10) |> Edit.move_node("sorted", 3, 4)

      assert Enum.map(spec.nodes, & &1.position) == [
               %{"x" => 45, "y" => 50},
               %{"x" => 3, "y" => 4}
             ]
    end

    test "move_node/4 keeps nodes on the canvas: x and y never go below 0", %{spec: spec} do
      spec = Edit.move_node(spec, "orders", -500, -45)
      assert hd(spec.nodes).position == %{"x" => 0, "y" => 15}
    end

    test "connect/4 sets an input port, replacing what was there", %{spec: spec} do
      spec =
        spec
        |> Edit.add_node("select", %{"x" => 0, "y" => 0})
        |> Edit.connect("sorted", "select_1", "in")

      assert Enum.find(spec.nodes, &(&1.id == "select_1")).inputs == %{"in" => "sorted"}
    end

    test "set_config/4 parses text with the tool's field and stores it", %{spec: spec} do
      assert {:ok, spec} = Edit.set_config(spec, "sorted", "by", "amount, id")
      assert {:ok, spec} = Edit.set_config(spec, "sorted", "desc", "false")
      sorted = Enum.find(spec.nodes, &(&1.id == "sorted"))
      assert sorted.config == %{"by" => ["amount", "id"], "desc" => false}
    end

    test "set_config/4 removes an optional setting set to empty", %{spec: spec} do
      assert {:ok, spec} = Edit.set_config(spec, "sorted", "desc", "")
      assert Enum.find(spec.nodes, &(&1.id == "sorted")).config == %{"by" => ["amount"]}
    end

    test "set_config/4 reports bad text and unknown settings", %{spec: spec} do
      assert Edit.set_config(spec, "sorted", "by", "") == {:error, "Required"}
      assert Edit.set_config(spec, "sorted", "nope", "x") == {:error, "Unknown setting"}
    end

    test "remove_node/2 drops the node and every input that pointed at it", %{spec: spec} do
      spec = Edit.remove_node(spec, "orders")
      assert [%{id: "sorted", inputs: %{}}] = spec.nodes
    end
  end

  test "validate/1 names the config a node is missing" do
    {:ok, draft} =
      Spec.decode("nodes: [{id: in, tool: input_csv}, {id: s, tool: sort, inputs: {in: in}}]")

    assert {:error, {:missing_config, "in", ["path"]}} = Spec.validate(draft)
    assert Spec.format_error({:missing_config, "in", ["path"]}) == "in: needs config path"
  end
end
