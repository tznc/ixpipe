defmodule IxpipeCore.ScriptTest do
  # Each language's tests are tagged `script: language` and excluded when its
  # runtime isn't installed (test_helper.exs).
  use ExUnit.Case, async: true

  alias IxpipeCore.{Context, Script, Table}
  alias IxpipeCore.Tools.Script, as: ScriptTool

  setup do
    ctx = Context.new("s")

    src =
      Table.new(ctx.db, "src",
        id: [1, 2, 3],
        name: ["a", "b", "c"],
        day: [~D[2026-01-01], nil, ~D[2026-01-03]]
      )

    %{ctx: ctx, src: src}
  end

  defp run!(ctx, src, language, code, config \\ %{}) do
    ScriptTool.run(
      %{"in" => src},
      Map.merge(%{"language" => language, "code" => code}, config),
      ctx
    )
  end

  defp failure(ctx, src, language, code, config \\ %{}) do
    assert_raise(RuntimeError, fn -> run!(ctx, src, language, code, config) end)
    |> Exception.message()
  end

  test "a missing runtime says what happened and what to do" do
    assert {:error, message} = Script.runtime("python", "/nowhere/python3")

    assert message ==
             "Python isn't installed at /nowhere/python3. Install it, or set Interpreter to a Python 3 executable."

    assert {:error, message} = Script.runtime("r", nil)
    assert message =~ "R isn't supported"
  end

  test "runtimes/0 lists every language with what was found" do
    for %{language: language, label: label, found: found} <- Script.runtimes() do
      assert language in Script.languages()
      assert is_binary(label)
      assert match?({:ok, _}, found) or match?({:error, _}, found)
    end
  end

  test "the tool says so when its runtime is missing", %{ctx: ctx, src: src} do
    message = failure(ctx, src, "python", "output = []", %{"interpreter" => "/nowhere/python3"})
    assert message =~ "Python isn't installed at /nowhere/python3."
  end

  @snippets %{
    "python" => %{
      ok: ~S"""
      print("rows", len(inputs["in"]))
      output = [{"id": r["id"], "upper": r["name"].upper(), "day": r["day"]} for r in inputs["in"]]
      """,
      fail: "x = 1\nraise ValueError('bad value')\n",
      loop: "while True:\n    pass\n",
      parquet: ~S"""
      import pandas as pd
      df = pd.read_parquet(inputs["in"])
      df["twice"] = df["id"] * 2
      output = df
      """
    },
    "javascript" => %{
      ok: ~S"""
      console.log("rows", inputs.in.length);
      output = inputs.in.map(r => ({id: r.id, upper: r.name.toUpperCase(), day: r.day}));
      """,
      fail: "const x = 1;\nthrow new Error('bad value');\n",
      loop: "while (true) {}\n"
    },
    "ruby" => %{
      ok: ~S"""
      puts "rows #{inputs["in"].length}"
      output = inputs["in"].map { |r| {"id" => r["id"], "upper" => r["name"].upcase, "day" => r["day"]} }
      """,
      fail: "x = 1\nraise ArgumentError, 'bad value'\n",
      loop: "loop {}\n"
    },
    "php" => %{
      ok: ~S"""
      echo "rows " . count($inputs["in"]) . "\n";
      $output = array_map(fn($r) => ["id" => $r["id"], "upper" => strtoupper($r["name"]), "day" => $r["day"]], $inputs["in"]);
      """,
      fail: "$x = 1;\nthrow new Exception('bad value');\n",
      loop: "while (true) {}\n"
    }
  }

  for {language, snippet} <- @snippets do
    describe language do
      @describetag script: language

      test "rows go in and out, typed by DuckDB, with stdout in the log", %{ctx: ctx, src: src} do
        %{"out" => out, "log" => log} = run!(ctx, src, unquote(language), unquote(snippet.ok))

        assert Table.to_columns(out) == %{
                 "id" => [1, 2, 3],
                 "upper" => ["A", "B", "C"],
                 "day" => [~D[2026-01-01], nil, ~D[2026-01-03]]
               }

        assert Table.dtypes(out)["id"] == "BIGINT"
        assert %{"stream" => ["stdout"], "line" => ["rows 3"]} = Table.to_columns(log)
      end

      test "an error names its line and says what to do", %{ctx: ctx, src: src} do
        message = failure(ctx, src, unquote(language), unquote(snippet.fail))
        assert message =~ "bad value"
        assert message =~ "line 2"
        assert message =~ "Fix the script and run again."
      end

      test "a script past its time limit is stopped", %{ctx: ctx, src: src} do
        {time, message} =
          :timer.tc(fn ->
            failure(ctx, src, unquote(language), unquote(snippet.loop), %{"time_limit" => 1})
          end)

        assert message =~ "ran past its time limit of 1 s"
        assert time < 10_000_000
      end

      test "inputs above the row limit are cut, with a warning", %{ctx: ctx, src: src} do
        %{"out" => out, "log" => log} =
          run!(ctx, src, unquote(language), unquote(snippet.ok), %{"row_limit" => 2})

        assert Table.count(out) == 2
        assert %{"stream" => ["warning", "stdout"]} = Table.to_columns(log)
      end

      if snippet[:parquet] do
        @tag :pandas
        test "parquet hands the script file paths", %{ctx: ctx, src: src} do
          %{"out" => out} =
            run!(ctx, src, unquote(language), unquote(snippet[:parquet]), %{"format" => "parquet"})

          assert Table.to_columns(out)["twice"] == [2, 4, 6]
        end
      end
    end
  end
end
