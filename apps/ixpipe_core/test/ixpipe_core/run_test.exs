defmodule IxpipeCore.RunTest do
  use ExUnit.Case, async: true
  alias Explorer.DataFrame, as: DF

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    out = Path.join(System.tmp_dir!(), "ixpipe-#{System.unique_integer([:positive])}.csv")
    on_exit(fn -> File.rm(out) end)
    %{out: out}
  end

  defp run!(yaml) do
    {:ok, spec} = IxpipeCore.Spec.parse(yaml)
    {:ok, results} = IxpipeCore.run(spec)
    results
  end

  test "input -> select -> sort -> output", %{out: out} do
    results =
      run!("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - {id: slim, tool: select, inputs: {in: orders}, config: {columns: [id, amount]}}
        - {id: sorted, tool: sort, inputs: {in: slim}, config: {by: [amount], desc: true}}
        - {id: out, tool: output_csv, inputs: {in: sorted}, config: {path: #{out}}}
      """)

    assert DF.names(results["slim"]) == ["id", "amount"]
    assert DF.to_columns(results["sorted"])["amount"] == [50, 30, 12, 5]
    assert File.read!(out) == "id,amount\n1,50\n3,30\n4,12\n2,5\n"
  end

  test "join matches left and right ports on keys" do
    results =
      run!("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - {id: customers, tool: input_csv, config: {path: #{@fixtures}/customers.csv}}
        - id: joined
          tool: join
          inputs: {left: orders, right: customers}
          config: {on: [customer_id]}
        - {id: sorted, tool: sort, inputs: {in: joined}, config: {by: [id]}}
      """)

    assert DF.to_columns(results["sorted"])["name"] == ["Ada", "Bob", "Ada", "Cy"]
  end

  test "summarize groups and aggregates" do
    results =
      run!("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - id: totals
          tool: summarize
          inputs: {in: orders}
          config:
            group_by: [customer_id]
            aggregates:
              - {column: amount, op: sum, as: total}
              - {column: id, op: count, as: orders}
        - {id: sorted, tool: sort, inputs: {in: totals}, config: {by: [customer_id]}}
      """)

    cols = DF.to_columns(results["sorted"])
    assert cols["total"] == [80, 5, 12]
    assert cols["orders"] == [2, 1, 1]
  end

  test "nodes with identical tool and config both run" do
    results =
      run!("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - {id: a, tool: sort, inputs: {in: orders}, config: {by: [amount]}}
        - {id: b, tool: sort, inputs: {in: orders}, config: {by: [amount]}}
      """)

    assert DF.n_rows(results["a"]) == 4
    assert DF.n_rows(results["b"]) == 4
  end

  test "a failing node fails the run with its id and reason" do
    {:ok, spec} =
      IxpipeCore.Spec.parse("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: /nonexistent.csv}}
        - {id: sorted, tool: sort, inputs: {in: orders}, config: {by: [id]}}
      """)

    assert {:error, {:node_failed, "orders", message}} = IxpipeCore.run(spec)
    assert message =~ "nonexistent.csv"
  end

  test "union stacks rows from a and b" do
    results =
      run!("""
      nodes:
        - {id: x, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - {id: y, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - {id: both, tool: union, inputs: {a: x, b: y}}
      """)

    assert DF.n_rows(results["both"]) == 8
  end

  test "sample keeps the first or last n rows" do
    results =
      run!("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - {id: head, tool: sample, inputs: {in: orders}, config: {n: 2}}
        - {id: tail, tool: sample, inputs: {in: orders}, config: {n: 1, from: last}}
      """)

    assert DF.to_columns(results["head"])["id"] == [1, 2]
    assert DF.to_columns(results["tail"])["id"] == [4]
  end

  test "unique drops duplicate rows, or rows repeating the given columns" do
    results =
      run!("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - {id: twice, tool: union, inputs: {a: orders, b: orders}}
        - {id: rows, tool: unique, inputs: {in: twice}}
        - {id: customers, tool: unique, inputs: {in: orders}, config: {columns: [customer_id]}}
      """)

    assert DF.n_rows(results["rows"]) == 4
    assert DF.to_columns(results["customers"])["id"] == [1, 2, 4]
  end

  test "a node can read the same input on two ports" do
    results =
      run!("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - {id: self, tool: join, inputs: {left: orders, right: orders}, config: {on: [id]}}
      """)

    assert DF.n_rows(results["self"]) == 4
  end
end
