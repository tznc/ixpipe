defmodule IxpipeCore.MacroTest do
  use ExUnit.Case, async: true
  alias IxpipeCore.{Macro, Spec, Table, Tools}

  @fixtures Path.expand("../fixtures", __DIR__)

  # big.yaml: keeps the rows of `rows` whose amount is over `threshold`.
  @big """
  name: Big orders
  macro:
    parameters:
      - {name: threshold, type: integer, label: Threshold, default: 10}
  nodes:
    - {id: rows, tool: macro_input, config: {columns: [amount]}}
    - {id: f, tool: filter, inputs: {in: rows}, config: {expr: "amount > {{threshold}}"}}
    - {id: big, tool: macro_output, inputs: {in: f.true}}
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-macro-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "big.yaml"), @big)
    %{dir: dir}
  end

  defp write(dir, file, yaml) do
    path = Path.join(dir, file)
    File.write!(path, yaml)
    path
  end

  defp load(dir, yaml) do
    path = write(dir, "main.yaml", yaml)
    with {:ok, spec} <- Spec.decode(File.read!(path), path: path), do: Spec.validate(spec)
  end

  defp run!(dir, yaml, opts \\ []) do
    {:ok, spec} = load(dir, yaml)
    {:ok, results} = IxpipeCore.run(spec, opts)
    results
  end

  defp orders, do: "{id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}"

  describe "a standard macro" do
    test "is a node whose ports and fields come from its declaration", %{dir: dir} do
      {:ok, spec} =
        load(dir, """
        nodes:
          - #{orders()}
          - {id: m, tool: macro, inputs: {rows: orders}, config: {path: big.yaml}}
        """)

      node = Enum.find(spec.nodes, &(&1.id == "m"))
      assert node.tool == Tools.Macro
      assert Tools.inputs(node) == ["rows"]
      assert Tools.outputs(node) == ["big"]

      assert [%{key: "path", type: :path}, %{key: "threshold", type: :integer} = threshold] =
               Tools.fields(node)

      assert threshold.label == "Threshold"
      assert threshold.default == 10
      assert threshold.optional
      assert node.macro.name == "Big orders"
    end

    test "runs the inner workflow with its parameters", %{dir: dir} do
      results =
        run!(dir, """
        nodes:
          - #{orders()}
          - {id: m, tool: macro, inputs: {rows: orders}, config: {path: big.yaml, threshold: 20}}
          - {id: sorted, tool: sort, inputs: {in: m}, config: {by: [amount]}}
        """)

      assert Table.to_columns(results["sorted"])["amount"] == [30, 50]
      assert results["m"].name == "m"
    end

    test "a parameter's default applies when the node does not set it", %{dir: dir} do
      results =
        run!(dir, """
        nodes:
          - #{orders()}
          - {id: m, tool: macro, inputs: {rows: orders}, config: {path: big.yaml}}
        """)

      assert Table.count(results["m"]) == 3
    end

    test "parameters substitute into SQL as literals, never as SQL", %{dir: dir} do
      write(dir, "region.yaml", """
      macro:
        parameters: [{name: name, type: string}]
      nodes:
        - {id: rows, tool: macro_input}
        - {id: f, tool: formula, inputs: {in: rows}, config: {formulas: [{as: who, expr: "{{name}}"}]}}
        - {id: out, tool: macro_output, inputs: {in: f}}
      """)

      results =
        run!(dir, """
        nodes:
          - #{orders()}
          - {id: m, tool: macro, inputs: {rows: orders}, config: {path: region.yaml, name: "x' OR 1=1 --"}}
        """)

      assert Enum.uniq(Table.to_columns(results["m"])["who"]) == ["x' OR 1=1 --"]
    end

    test "inner tables are namespaced under the node", %{dir: dir} do
      results =
        run!(dir, """
        nodes:
          - #{orders()}
          - {id: f, tool: macro, inputs: {rows: orders}, config: {path: big.yaml}}
          - {id: g, tool: macro, inputs: {rows: orders}, config: {path: big.yaml, threshold: 40}}
        """)

      assert Table.count(results["f"]) == 3
      assert Table.count(results["g"]) == 1
      db = results["f"].db
      {:ok, %{rows: names}} = IxpipeCore.Duck.query(db, "SELECT table_name FROM duckdb_tables()")
      names = List.flatten(names)
      assert "f/f.true" in names
      assert "g/f.true" in names
    end

    test "an inner failure names the inner tool", %{dir: dir} do
      write(dir, "bad.yaml", """
      nodes:
        - {id: rows, tool: macro_input}
        - {id: f, tool: filter, inputs: {in: rows}, config: {expr: "nope > 1"}}
        - {id: out, tool: macro_output, inputs: {in: f.true}}
      """)

      {:ok, spec} =
        load(dir, """
        nodes:
          - #{orders()}
          - {id: m, tool: macro, inputs: {rows: orders}, config: {path: bad.yaml}}
        """)

      assert {:error, {:node_failed, "m/f", message}} = IxpipeCore.run(spec)
      assert message =~ "nope"
    end

    test "a macro input checks the columns it expects", %{dir: dir} do
      write(dir, "needs.yaml", """
      nodes:
        - {id: rows, tool: macro_input, config: {columns: [amount, colour]}}
        - {id: out, tool: macro_output, inputs: {in: rows}}
      """)

      {:ok, spec} =
        load(dir, """
        nodes:
          - #{orders()}
          - {id: m, tool: macro, inputs: {rows: orders}, config: {path: needs.yaml}}
        """)

      assert {:error, {:node_failed, "m/rows", message}} = IxpipeCore.run(spec)
      assert message =~ "colour"
    end

    test "macros nest, each relative to its own folder", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.cp!(Path.join(dir, "big.yaml"), Path.join(dir, "lib/big.yaml"))

      write(dir, "lib/outer.yaml", """
      macro:
        parameters: [{name: over, type: integer, default: 40}]
      nodes:
        - {id: rows, tool: macro_input}
        - {id: inner, tool: macro, inputs: {rows: rows}, config: {path: big.yaml, threshold: "{{over}}"}}
        - {id: out, tool: macro_output, inputs: {in: inner}}
      """)

      results =
        run!(dir, """
        nodes:
          - #{orders()}
          - {id: m, tool: macro, inputs: {rows: orders}, config: {path: lib/outer.yaml}}
        """)

      assert Table.to_columns(results["m"])["amount"] == [50]
    end

    test "several inputs and outputs", %{dir: dir} do
      write(dir, "split.yaml", """
      nodes:
        - {id: a, tool: macro_input}
        - {id: b, tool: macro_input}
        - {id: u, tool: union, inputs: {a: a, b: b}}
        - {id: f, tool: filter, inputs: {in: u}, config: {expr: "amount > 10"}}
        - {id: high, tool: macro_output, inputs: {in: f.true}}
        - {id: low, tool: macro_output, inputs: {in: f.false}}
      """)

      results =
        run!(dir, """
        nodes:
          - #{orders()}
          - {id: m, tool: macro, inputs: {a: orders, b: orders}, config: {path: split.yaml}}
          - {id: s, tool: sort, inputs: {in: m.low}, config: {by: [amount]}}
        """)

      assert Table.count(results["m.high"]) == 6
      assert Table.to_columns(results["s"])["amount"] == [5, 5]
    end

    test "a macro that uses itself is rejected", %{dir: dir} do
      write(dir, "self.yaml", """
      nodes:
        - {id: rows, tool: macro_input}
        - {id: again, tool: macro, inputs: {rows: rows}, config: {path: self.yaml}}
        - {id: out, tool: macro_output, inputs: {in: again}}
      """)

      assert {:error, reason} =
               load(dir, """
               nodes:
                 - #{orders()}
                 - {id: m, tool: macro, inputs: {rows: orders}, config: {path: self.yaml}}
               """)

      assert Spec.format_error(reason) =~ "self.yaml -> self.yaml"
    end

    test "an indirect cycle is rejected", %{dir: dir} do
      write(dir, "a.yaml", """
      nodes:
        - {id: rows, tool: macro_input}
        - {id: b, tool: macro, inputs: {rows: rows}, config: {path: b.yaml}}
        - {id: out, tool: macro_output, inputs: {in: b}}
      """)

      write(dir, "b.yaml", """
      nodes:
        - {id: rows, tool: macro_input}
        - {id: a, tool: macro, inputs: {rows: rows}, config: {path: a.yaml}}
        - {id: out, tool: macro_output, inputs: {in: a}}
      """)

      assert {:error, reason} =
               load(dir, """
               nodes:
                 - #{orders()}
                 - {id: m, tool: macro, inputs: {rows: orders}, config: {path: a.yaml}}
               """)

      assert Spec.format_error(reason) =~ "macro cycle: a.yaml -> b.yaml -> a.yaml"
    end

    test "a workflow that uses itself as a macro is rejected", %{dir: dir} do
      assert {:error, reason} =
               load(dir, """
               nodes:
                 - {id: rows, tool: macro_input}
                 - {id: m, tool: macro, inputs: {rows: rows}, config: {path: main.yaml}}
               """)

      assert Spec.format_error(reason) =~ "macro cycle: main.yaml -> main.yaml"
    end

    test "a missing macro file and an unknown parameter are clear errors", %{dir: dir} do
      assert {:error, reason} =
               load(dir, """
               nodes:
                 - {id: m, tool: macro, config: {path: nowhere.yaml}}
               """)

      assert Spec.format_error(reason) == "m: no macro at nowhere.yaml"

      write(dir, "typo.yaml", """
      nodes:
        - {id: rows, tool: macro_input}
        - {id: f, tool: filter, inputs: {in: rows}, config: {expr: "amount > {{treshold}}"}}
        - {id: out, tool: macro_output, inputs: {in: f.true}}
      """)

      assert {:error, reason} =
               load(dir, "nodes: [{id: m, tool: macro, config: {path: typo.yaml}}]")

      assert Spec.format_error(reason) =~ "typo.yaml: f uses an unknown parameter treshold"
    end

    test "a macro node whose macro was never loaded fails clearly" do
      spec = %Spec{nodes: [%Spec.Node{id: "m", tool: Tools.Macro, config: %{"path" => "x.yaml"}}]}
      assert {:error, {:node_failed, "m", message}} = IxpipeCore.run(spec)
      assert message =~ "isn't loaded"
    end

    test "a required parameter must be set", %{dir: dir} do
      write(dir, "req.yaml", """
      macro:
        parameters: [{name: limit, type: integer}]
      nodes:
        - {id: rows, tool: macro_input}
        - {id: out, tool: macro_output, inputs: {in: rows}}
      """)

      assert {:error, {:missing_config, "m", ["limit"]}} =
               load(dir, """
               nodes:
                 - #{orders()}
                 - {id: m, tool: macro, inputs: {rows: orders}, config: {path: req.yaml}}
               """)
    end

    test "file?/1 tells a macro file from a workflow", %{dir: dir} do
      assert Macro.file?(Path.join(dir, "big.yaml"))
      refute Macro.file?(write(dir, "plain.yaml", "nodes: [#{orders()}]"))
      assert Macro.file?(write(dir, "ports.yaml", "nodes: [{id: a, tool: macro_input}]"))
      refute Macro.file?(write(dir, "broken.yaml", "nodes: ["))
    end

    test "the macro header survives a round trip", %{dir: dir} do
      {:ok, spec} = Spec.decode(@big, path: Path.join(dir, "big.yaml"))
      assert Macro.macro?(spec)
      {:ok, again} = Spec.decode(Spec.to_yaml(spec))
      assert again.macro == spec.macro
    end

    test "run on its own, a macro uses its parameters' defaults and sample data", %{dir: dir} do
      path =
        write(dir, "alone.yaml", """
        macro:
          parameters: [{name: threshold, type: integer, default: 20}]
        nodes:
          - {id: rows, tool: macro_input, config: {path: #{@fixtures}/orders.csv}}
          - {id: f, tool: filter, inputs: {in: rows}, config: {expr: "amount > {{threshold}}"}}
          - {id: big, tool: macro_output, inputs: {in: f.true}}
        """)

      {:ok, spec} = Spec.decode(File.read!(path), path: path)
      {:ok, spec} = Spec.validate(spec)
      {:ok, results} = IxpipeCore.run(spec)
      assert Table.count(results["big"]) == 2

      {:ok, results} = IxpipeCore.run(spec, params: %{"threshold" => 40})
      assert Table.count(results["big"]) == 1
    end
  end

  describe "a batch macro" do
    setup %{dir: dir} do
      write(dir, "per.yaml", """
      macro:
        type: batch
        parameters: [{name: threshold, type: integer, default: 0}, {name: tag, type: string, default: x}]
      nodes:
        - {id: rows, tool: macro_input}
        - {id: f, tool: filter, inputs: {in: rows}, config: {expr: "amount > {{threshold}}"}}
        - {id: t, tool: formula, inputs: {in: f.true}, config: {formulas: [{as: tag, expr: "{{tag}}"}]}}
        - {id: out, tool: macro_output, inputs: {in: t}}
      """)

      :ok
    end

    test "has a control input", %{dir: dir} do
      {:ok, spec} =
        load(dir, """
        nodes:
          - #{orders()}
          - {id: m, tool: macro, inputs: {rows: orders, control: orders}, config: {path: per.yaml}}
        """)

      assert Tools.inputs(Enum.find(spec.nodes, &(&1.id == "m"))) == ["rows", "control"]
    end

    test "runs once per control row and unions the outputs by name", %{dir: dir} do
      write(dir, "control.csv", "threshold,tag,note\n20,big,a\n40,huge,b\n20,big,c\n")

      results =
        run!(dir, """
        nodes:
          - #{orders()}
          - {id: control, tool: input_csv, config: {path: #{dir}/control.csv}}
          - {id: m, tool: macro, inputs: {rows: orders, control: control}, config: {path: per.yaml}}
          - {id: s, tool: sort, inputs: {in: m}, config: {by: [tag, amount]}}
        """)

      # Two batches: (20, big) and (40, huge); the repeated row is one batch.
      cols = Table.to_columns(results["s"])
      assert cols["tag"] == ["big", "big", "huge"]
      assert cols["amount"] == [30, 50, 50]
    end

    test "an empty control runs no batch and outputs no rows", %{dir: dir} do
      write(dir, "control.csv", "threshold,tag\n")

      results =
        run!(dir, """
        nodes:
          - #{orders()}
          - {id: control, tool: input_csv, config: {path: #{dir}/control.csv}}
          - {id: m, tool: macro, inputs: {rows: orders, control: control}, config: {path: per.yaml}}
        """)

      assert Table.count(results["m"]) == 0
    end
  end

  describe "an iterative macro" do
    # Each iteration halves amount; rows at or under 10 are done, the rest
    # go round again.
    @halve """
    macro:
      type: iterative
      iterate: {input: rows, output: again, max: 10}
    nodes:
      - {id: rows, tool: macro_input}
      - {id: h, tool: formula, inputs: {in: rows}, config: {formulas: [{as: amount, expr: amount // 2}]}}
      - {id: f, tool: filter, inputs: {in: h}, config: {expr: amount > 10}}
      - {id: done, tool: macro_output, inputs: {in: f.false}}
      - {id: again, tool: macro_output, inputs: {in: f.true}}
    """

    test "repeats until the iteration output is empty and reports the iterations", %{dir: dir} do
      write(dir, "halve.yaml", @halve)

      results =
        run!(dir, """
        nodes:
          - #{orders()}
          - {id: m, tool: macro, inputs: {rows: orders}, config: {path: halve.yaml}}
          - {id: s, tool: sort, inputs: {in: m.done}, config: {by: [id]}}
        """)

      # 12 -> 6; 30 -> 15 -> 7; 50 -> 25 -> 12 -> 6; 5 -> 2
      assert Table.to_columns(results["s"])["amount"] == [6, 2, 7, 6]
      assert Table.count(results["m.again"]) == 0
      assert Table.to_columns(results["m.iterations"]) == %{"iterations" => [3]}
    end

    test "stops at the maximum, which the node can lower", %{dir: dir} do
      write(dir, "halve.yaml", @halve)

      {:ok, spec} =
        load(dir, """
        nodes:
          - #{orders()}
          - {id: m, tool: macro, inputs: {rows: orders}, config: {path: halve.yaml, max_iterations: 1}}
        """)

      m = Enum.find(spec.nodes, &(&1.id == "m"))
      assert Tools.outputs(m) == ["done", "again", "iterations"]
      assert %{key: "max_iterations", default: 10} = List.last(Tools.fields(m))

      {:ok, results} = IxpipeCore.run(spec)
      assert Table.to_columns(results["m.iterations"]) == %{"iterations" => [1]}
      assert Table.count(results["m.again"]) == 2
    end
  end
end
