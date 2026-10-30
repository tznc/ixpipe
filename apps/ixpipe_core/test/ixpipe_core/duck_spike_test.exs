defmodule IxpipeCore.DuckSpikeTest do
  # Spike: DuckDB as the engine. The same workflow must give the same
  # results through DuckDB (IxpipeCore.DuckRun) as through Explorer.
  use ExUnit.Case, async: true
  alias Explorer.DataFrame, as: DF
  alias IxpipeCore.{Duck, DuckRun, Spec}

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-duck-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    csv = Path.join(dir, "orders.csv")

    File.write!(csv, """
    id,customer,amount
    1,ada,50.5
    2,bob,5
    3,ada,30
    4,cy,12
    5,bob,
    """)

    {:ok, spec} =
      Spec.parse("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: #{csv}}}
        - {id: big, tool: filter, inputs: {in: orders}, config: {expr: amount > 10}}
        - {id: taxed, tool: formula, inputs: {in: big.true}, config: {formulas: [{as: tax, expr: amount * 0.1}, {as: customer, expr: upper(customer)}]}}
        - {id: totals, tool: summarize, inputs: {in: taxed}, config: {group_by: [customer], aggregates: [{column: amount, op: sum, as: total}, {column: tax, op: mean, as: avg_tax}, {column: id, op: count, as: n}]}}
      """)

    %{spec: spec}
  end

  defp rows(df), do: df |> DF.sort_with(&[&1[0]]) |> DF.to_rows()

  test "query returns a frame through Arrow" do
    assert {:ok, df} = Duck.frame("SELECT 1 AS a, 'x' AS b, NULL::DOUBLE AS c")
    assert DF.to_rows(df) == [%{"a" => 1, "b" => "x", "c" => nil}]
  end

  test "errors are messages" do
    assert {:error, message} = Duck.frame("SELECT * FROM nope")
    assert message =~ "nope"
  end

  test "every node gives the same result as Explorer", %{spec: spec} do
    {:ok, explorer} = IxpipeCore.run(spec)
    {:ok, duck} = DuckRun.run(spec)

    assert Enum.sort(Map.keys(duck)) == Enum.sort(Map.keys(explorer))

    for {key, expected} <- explorer do
      assert DF.names(duck[key]) == DF.names(expected), key
      assert rows(duck[key]) == rows(expected), key
    end
  end

  test "only the outputs asked for", %{spec: spec} do
    {:ok, duck} = DuckRun.run(spec, only: ["totals"])
    assert Map.keys(duck) == ["totals"]
  end
end
