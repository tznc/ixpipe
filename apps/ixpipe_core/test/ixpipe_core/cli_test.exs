defmodule IxpipeCore.CLITest do
  use ExUnit.Case, async: true
  alias IxpipeCore.CLI

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp!(Path.join(@fixtures, "orders.csv"), Path.join(dir, "orders.csv"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp workflow(dir, yaml) do
    path = Path.join(dir, "flow.yaml")
    File.write!(path, yaml)
    path
  end

  defp cli(argv) do
    {:ok, io} = StringIO.open("")
    code = CLI.main(argv, io)
    {:ok, {_, out}} = StringIO.close(io)
    {code, out}
  end

  @flow """
  name: flow
  nodes:
    - {id: orders, tool: input_csv, config: {path: orders.csv}}
    - {id: big, tool: filter, inputs: {in: orders}, config: {expr: "amount > 10"}}
    - {id: out, tool: output_csv, inputs: {in: big}, config: {path: big.csv}}
  """

  test "run prints a line per tool and a summary, resolving relative paths", %{dir: dir} do
    {code, out} = cli(["run", workflow(dir, @flow)])

    assert code == 0
    assert out =~ ~r/orders\s+input_csv\s+4 rows/
    assert out =~ ~r/big\s+filter\s+3 rows/
    assert out =~ ~r/Run succeeded in \d+ ms/
    # Relative paths resolve against the workflow's directory.
    assert File.read!(Path.join(dir, "big.csv")) =~ "amount"
  end

  test "--json prints one object", %{dir: dir} do
    {code, out} = cli(["run", workflow(dir, @flow), "--json"])
    assert code == 0

    assert %{"status" => "ok", "error" => nil, "ms" => ms, "nodes" => nodes} = Jason.decode!(out)
    assert is_integer(ms)
    assert %{"id" => "orders", "tool" => "input_csv", "rows" => 4} = hd(nodes)
    assert Enum.map(nodes, & &1["id"]) == ["orders", "big", "out"]
  end

  test "--output-dir writes outputs with relative paths there", %{dir: dir} do
    out_dir = Path.join(dir, "out")
    {0, _} = cli(["run", workflow(dir, @flow), "--output-dir", out_dir])
    assert File.exists?(Path.join(out_dir, "big.csv"))
    refute File.exists?(Path.join(dir, "big.csv"))
  end

  test "a workflow that is not runnable fails with the reason and exit 1", %{dir: dir} do
    path = workflow(dir, "nodes: [{id: s, tool: sort}]")
    assert {1, out} = cli(["run", path])
    assert out =~ "s: expects inputs [in], got []"

    assert {1, json} = cli(["run", path, "--json"])

    assert %{"status" => "error", "error" => "s: expects inputs [in], got []"} =
             Jason.decode!(json)
  end

  test "a failing tool fails the run with its id", %{dir: dir} do
    path = workflow(dir, "nodes: [{id: orders, tool: input_csv, config: {path: nope.csv}}]")
    assert {1, out} = cli(["run", path])
    assert out =~ "orders failed:"
  end

  test "validate checks without running", %{dir: dir} do
    assert {0, out} = cli(["validate", workflow(dir, @flow)])
    assert out =~ "Valid: 3 tools"
    refute File.exists?(Path.join(dir, "big.csv"))

    assert {1, out} = cli(["validate", workflow(dir, "nodes: [{id: a, tool: nope}]")])
    assert out =~ ~s(a: unknown tool "nope")
  end

  test "usage errors exit 2 with the usage text" do
    assert {2, out} = cli(["run", "/no/such/flow.yaml"])
    assert out =~ "No workflow at /no/such/flow.yaml"
    assert out =~ "Usage:"

    assert {2, out} = cli(["frobnicate"])
    assert out =~ "Usage:"

    assert {2, _} = cli([])
    assert {0, out} = cli(["help"])
    assert out =~ "ixpipe run"
  end
end
