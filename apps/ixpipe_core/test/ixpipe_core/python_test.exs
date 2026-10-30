defmodule IxpipeCore.PythonTest do
  use ExUnit.Case, async: true

  alias IxpipeCore.{Context, Python, Table}
  alias IxpipeCore.Tools.Python, as: PythonTool

  defp run(code, inputs \\ %{}, opts \\ []), do: Python.run(code, inputs, opts)

  defp error(code, opts \\ []) do
    assert {:error, error} = run(code, %{}, opts)
    error
  end

  describe "data" do
    test "inputs arrive as lists of dicts and output comes back as rows" do
      inputs = %{"in" => {["id", "name"], [[1, "a"], [2, "b"]]}}

      assert {:ok, %{columns: ["id", "name", "twice"], rows: rows}} =
               run(
                 ~S"""
                 output = [{**r, "twice": r["id"] * 2} for r in inputs["in"]]
                 """,
                 inputs
               )

      assert rows == [[1, "a", 2], [2, "b", 4]]
    end

    test "output may be a dict of columns" do
      assert {:ok, %{columns: ["x", "y"], rows: [[1, "p"], [2, "q"]]}} =
               run(~s|output = {"x": [1, 2], "y": ["p", "q"]}|)
    end

    test "dates, times, floats, booleans and None round-trip" do
      row = [~D[2026-01-31], ~N[2026-01-31 12:30:00.250000], ~T[08:15:00.000000], 1.5, true, nil]
      columns = ~w(d ts t f b n)

      assert {:ok, %{columns: ^columns, rows: [^row]}} =
               run("output = inputs['in']", %{"in" => {columns, [row]}})

      assert {:ok, %{rows: [[2026, 31, 8]]}} =
               run(
                 ~S"""
                 r = inputs["in"][0]
                 output = [{"y": r["d"].year, "day": r["ts"].day, "h": r["t"].hour}]
                 """,
                 %{"in" => {columns, [row]}}
               )
    end

    test "integers too large for 64 bits come back as text" do
      assert {:ok, %{rows: [["18446744073709551616"]]}} = run("output = [{'n': 2 ** 64}]")
    end

    test "print goes to stdout" do
      assert {:ok, %{stdout: "hello 3\n"}} = run("print('hello', 1 + 2)\noutput = []")
    end

    test "a script that sets no output says what to do" do
      error = error("x = 1")
      assert error.message =~ "didn't set output"
      assert error.message =~ "Assign a list of dicts"
    end

    test "output of the wrong shape says what to do" do
      assert error("output = 42").message =~ "Assign a list of dicts"
    end
  end

  describe "errors" do
    test "an exception names its type, line and message, with the traceback" do
      error = error("x = 1\ny = 0\nz = x / y\n")
      assert error.message == "Python raised ZeroDivisionError on line 3: division by zero."
      assert error.traceback =~ ~s(File "script.py", line 3)
      assert error.traceback =~ "ZeroDivisionError"
    end

    test "a syntax error names its line" do
      error = error("x = 1\nif x\n  y = 2\n")
      assert error.message =~ ~r/^Python raised SyntaxError on line 2/
    end

    test "stdout printed before the error is kept" do
      assert %{stdout: "before\n"} = error("print('before')\nraise ValueError('bad')")
    end
  end

  describe "sandbox" do
    test "files cannot be opened" do
      error = error("open('/etc/passwd').read()")
      assert error.message =~ "PermissionError"
      assert error.message =~ "files"
    end

    for module <- ~w(os sys socket subprocess io pathlib shutil importlib ctypes _io posix) do
      test "import #{module} is blocked" do
        error = error("import #{unquote(module)}")
        assert error.message =~ "ImportError"
        assert error.message =~ "#{unquote(module)} isn't allowed"
      end
    end

    test "__import__, exec and from-imports go through the same allow-list" do
      assert error("__import__('os')").message =~ "os isn't allowed"
      assert error("exec('import socket')").message =~ "socket isn't allowed"
      assert error("from os import path").message =~ "os isn't allowed"
      assert error("eval(\"__import__('subprocess')\")").message =~ "subprocess isn't allowed"
    end

    test "allowed modules import" do
      code = ~S"""
      import math, json, re, datetime, collections, itertools, functools, statistics
      import decimal, fractions, random, string, textwrap, operator, heapq, bisect
      import typing, enum, copy, calendar, unicodedata, difflib, hashlib, base64
      output = [{"pi": round(math.pi, 2), "mean": statistics.mean([1, 2, 3])}]
      """

      assert {:ok, %{rows: [[3.14, 2]]}} = run(code)
    end

    test "no class reachable from object opens files or processes" do
      code = ~S"""
      names = sorted({c.__name__ for c in object.__subclasses__()})
      bad = [n for n in names if n in ("FileIO", "Popen", "socket", "DirEntry", "ScandirIterator")]
      output = [{"bad": ",".join(bad)}]
      """

      assert {:ok, %{rows: [[""]]}} = run(code)
    end

    test "an infinite loop stops at the time limit" do
      {time, error} = :timer.tc(fn -> error("while True:\n    pass\n", timeout: 300) end)
      assert error.kind == :timeout
      assert error.message =~ "ran past its time limit"
      assert time < 3_000_000
    end

    test "catching the interrupt doesn't escape the time limit" do
      code = ~S"""
      while True:
          try:
              while True:
                  pass
          except BaseException:
              pass
      """

      assert error(code, timeout: 300).kind == :timeout
    end

    test "growing past the memory limit stops the script" do
      code = "xs = []\nwhile True:\n    xs.append('x' * 1000)\n"
      error = error(code, memory: 32 * 1024 * 1024, timeout: 10_000)
      assert error.kind == :memory
      assert error.message =~ "memory limit"
    end

    test "deep recursion is a RecursionError, not a crash" do
      error = error("def f(n): return f(n + 1)\nf(0)")
      assert error.message =~ "RecursionError"
    end

    test "a run can be cancelled" do
      job = Python.job()
      task = Task.async(fn -> run("while True:\n    pass\n", %{}, job: job, timeout: 60_000) end)
      Process.sleep(100)
      :ok = Python.cancel(job)
      assert {:error, %{kind: :cancelled}} = Task.await(task, 5_000)
    end

    test "runs are independent" do
      assert {:ok, _} = run("import math\nmath.pi = 3\noutput = []")
      assert {:ok, %{rows: [[3.14]]}} = run("import math\noutput = [{'p': round(math.pi, 2)}]")
    end
  end

  describe "the Python tool" do
    setup do
      ctx = Context.new("py")
      src = Table.new(ctx.db, "src", id: [1, 2, 3], amount: [10.0, 20.0, 30.0])
      %{ctx: ctx, src: src}
    end

    test "returns the script's output and its stdout as the log", %{ctx: ctx, src: src} do
      code = ~S"""
      print("rows:", len(inputs["in"]))
      output = [{"id": r["id"], "taxed": r["amount"] * 1.1} for r in inputs["in"]]
      """

      %{"out" => out, "log" => log} = PythonTool.run(%{"in" => src}, %{"code" => code}, ctx)
      assert Table.to_columns(out) == %{"id" => [1, 2, 3], "taxed" => [11.0, 22.0, 33.0]}
      assert Table.dtypes(out) == %{"id" => "BIGINT", "taxed" => "DOUBLE"}
      assert out.name == "py.out"
      assert Table.to_columns(log) == %{"stream" => ["stdout"], "line" => ["rows: 3"]}
    end

    test "an empty output keeps the log", %{ctx: ctx, src: src} do
      %{"out" => out} = PythonTool.run(%{"in" => src}, %{"code" => "output = []"}, ctx)
      assert Table.count(out) == 0
    end

    test "inputs above the row limit are cut, with a warning", %{ctx: ctx, src: src} do
      code = "output = [{'n': len(inputs['in'])}]"
      config = %{"code" => code, "row_limit" => 2}
      %{"out" => out, "log" => log} = PythonTool.run(%{"in" => src}, config, ctx)
      assert Table.to_columns(out) == %{"n" => [2]}

      assert %{"stream" => ["warning"], "line" => [warning]} = Table.to_columns(log)
      assert warning =~ "first 2 of 3 rows"
    end

    test "a failing script raises what happened and what to do", %{ctx: ctx, src: src} do
      error =
        assert_raise RuntimeError, fn ->
          PythonTool.run(%{"in" => src}, %{"code" => "1 / 0"}, ctx)
        end

      message = Exception.message(error)

      assert message =~ "Python raised ZeroDivisionError on line 1: division by zero."
      assert message =~ "Fix the script and run again."
      assert message =~ "Traceback"
    end
  end
end
