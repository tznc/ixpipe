defmodule IxpipeCore.RunMessagesTest do
  use ExUnit.Case, async: true
  alias IxpipeCore.{Context, Message, Table}

  @fixtures Path.expand("../fixtures", __DIR__)

  defp execute(yaml) do
    {:ok, spec} = IxpipeCore.Spec.parse(yaml)
    IxpipeCore.execute(spec)
  end

  defp texts(run, node, level),
    do: for(%Message{node: ^node, level: ^level, text: t} <- run.messages, do: t)

  test "a run that succeeds reports each node ok with its rows and time" do
    run =
      execute("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - {id: big, tool: filter, inputs: {in: orders}, config: {expr: "amount > 20"}}
      """)

    assert run.status == :ok
    assert run.nodes == %{"orders" => :ok, "big" => :ok}
    assert Table.count(run.tables["orders"]) == 4
    assert [info] = texts(run, "orders", :info)
    assert info =~ ~r/^4 rows in \d+ ms$/
    assert [info] = texts(run, "big", :info)
    assert info =~ ~r/^true 2 rows, false 2 rows in \d+ ms$/
    assert is_integer(run.ms)
  end

  test "a failure keeps the other branches' tables and skips what is downstream" do
    run =
      execute("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - {id: bad, tool: filter, inputs: {in: orders}, config: {expr: "nope > 1"}}
        - {id: after, tool: sort, inputs: {in: bad.true}, config: {by: [id]}}
        - {id: fine, tool: sort, inputs: {in: orders}, config: {by: [amount]}}
      """)

    assert run.status == :failed
    assert run.nodes == %{"orders" => :ok, "bad" => :failed, "after" => :skipped, "fine" => :ok}
    assert Map.keys(run.tables) |> Enum.sort() == ["fine", "orders"]
    assert Table.to_columns(run.tables["fine"])["amount"] == [5, 12, 30, 50]

    assert [%Message{level: :error, text: text, detail: detail}] =
             Enum.filter(run.messages, &(&1.node == "bad" and &1.level == :error))

    assert text =~ ~s(Column "nope" isn't in the input.)
    assert detail =~ "Binder Error"
    assert [skipped] = texts(run, "after", :info)
    assert skipped =~ "Didn't run because bad failed."
  end

  test "a table's warnings are the node's warnings (Select's failed casts)" do
    run =
      execute("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - {id: text, tool: formula, inputs: {in: orders},
           config: {formulas: [{as: label, expr: "CASE WHEN amount > 20 THEN 'big' ELSE amount::VARCHAR END"}]}}
        - {id: typed, tool: select, inputs: {in: text},
           config: {columns: [{name: label, type: BIGINT}, gone]}}
      """)

    assert run.status == :ok

    assert texts(run, "typed", :warning) == [
             "gone is not in the input, so it was skipped.",
             "label: 2 values couldn't become BIGINT and are now NULL."
           ]
  end

  test "run/2 still returns tables, or the first failure" do
    {:ok, spec} =
      IxpipeCore.Spec.parse("""
      nodes:
        - {id: orders, tool: input_csv, config: {path: /nonexistent.csv}}
        - {id: sorted, tool: sort, inputs: {in: orders}, config: {by: [id]}}
      """)

    assert {:error, {:node_failed, "orders", message}} = IxpipeCore.run(spec)
    assert message =~ "nonexistent.csv"
  end

  test "messages come in workflow order, errors and warnings before info" do
    run =
      execute("""
      nodes:
        - {id: a, tool: input_csv, config: {path: #{@fixtures}/orders.csv}}
        - id: f
          tool: formula
          inputs: {in: a}
          config: {formulas: [{as: blank, expr: "amount * NULL"}]}
      """)

    assert [%{node: "a", level: :info}, %{node: "f", level: :warning}, %{node: "f", level: :info}] =
             run.messages
  end

  describe "Context" do
    test "records warnings and info for its node, from any process" do
      ctx = Context.new("n")
      Context.warn(ctx, "careful")
      Task.await(Task.async(fn -> Context.info(ctx, "done") end))

      assert [%Message{node: "n", level: :warning, text: "careful"}, %Message{level: :info}] =
               Context.messages(ctx)
    end
  end
end
