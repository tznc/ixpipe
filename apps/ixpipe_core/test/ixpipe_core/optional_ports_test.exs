defmodule IxpipeCore.OptionalPortsTest do
  # A tool may leave some inputs unconnected (`optional_inputs/0`): Join
  # Multiple takes two to four inputs, and Generate Rows is a source unless
  # its `in` is connected.
  use ExUnit.Case, async: true
  alias IxpipeCore.{Spec, Table, Tools}

  defp run!(yaml) do
    {:ok, spec} = Spec.parse(yaml)
    {:ok, results} = IxpipeCore.run(spec)
    results
  end

  defp source(id, n),
    do:
      "- {id: #{id}, tool: generate_rows, config: {name: k, init: '1', condition: 'k <= #{n}', loop: 'k + 1'}}"

  test "optional_inputs/1 lists the ports a node may leave unconnected" do
    assert Tools.optional_inputs(Tools.JoinMultiple) == ["in3", "in4"]
    assert Tools.optional_inputs(Tools.GenerateRows) == ["in"]
    assert Tools.optional_inputs(Tools.Sort) == []
  end

  test "a node needs its required ports and may connect its optional ones" do
    assert {:error, {:bad_ports, "j", expected: ["in1", "in2", "in3", "in4"], got: ["in1"]}} =
             Spec.parse("""
             nodes:
               #{source("a", 1)}
               - {id: j, tool: join_multiple, inputs: {in1: a}, config: {on: [k]}}
             """)

    assert {:error, {:bad_ports, "j", expected: _, got: ["in1", "in2", "x"]}} =
             Spec.parse("""
             nodes:
               #{source("a", 1)}
               - {id: j, tool: join_multiple, inputs: {in1: a, in2: a, x: a}, config: {on: [k]}}
             """)

    assert {:ok, _} =
             Spec.parse("""
             nodes:
               #{source("a", 1)}
               - {id: j, tool: join_multiple, inputs: {in1: a, in2: a}, config: {on: [k]}}
             """)
  end

  test "a node with no ports connected runs as a source" do
    results = run!("nodes:\n  #{source("a", 3)}\n")
    assert Table.to_columns(results["a"]) == %{"k" => [1, 2, 3]}
  end

  test "a step reads three and four parents" do
    results =
      run!("""
      nodes:
        #{source("a", 4)}
        #{source("b", 3)}
        #{source("c", 2)}
        #{source("d", 1)}
        - {id: three, tool: join_multiple, inputs: {in1: a, in2: b, in3: c}, config: {on: [k], how: inner}}
        - id: four
          tool: join_multiple
          inputs: {in1: a, in2: b, in3: c, in4: d}
          config: {on: [k], how: inner}
      """)

    assert Table.to_columns(results["three"]) == %{"k" => [1, 2]}
    assert Table.to_columns(results["four"]) == %{"k" => [1]}
  end
end
