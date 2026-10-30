# Spike benchmark: Explorer vs DuckDB on one workflow.
#   mix run bench/duck_spike.exs gen ROWS DIR
#   mix run bench/duck_spike.exs explorer|duck|duck_all|duck_spill DIR
# Run each engine in its own OS process: peak memory is the process's VmHWM.
alias IxpipeCore.{Duck, DuckRun, Spec}

peak = fn ->
  "/proc/self/status" |> File.read!() |> then(&Regex.run(~r/VmHWM:\s+(\d+) kB/, &1)) |> Enum.at(1)
  |> String.to_integer() |> div(1024)
end

spec = fn dir, group ->
  {:ok, spec} =
    Spec.parse("""
    nodes:
      - {id: orders, tool: input_csv, config: {path: #{dir}/big.csv}}
      - {id: big, tool: filter, inputs: {in: orders}, config: {expr: amount > 100}}
      - {id: taxed, tool: formula, inputs: {in: big.true}, config: {formulas: [{as: tax, expr: amount * 0.1}, {as: region, expr: upper(region)}]}}
      - {id: totals, tool: summarize, inputs: {in: taxed}, config: {group_by: #{inspect(group)}, aggregates: [{column: amount, op: sum, as: total}, {column: tax, op: mean, as: avg_tax}, {column: id, op: count, as: n}]}}
    """)

  spec
end

time = fn label, f ->
  {us, result} = :timer.tc(f)
  {:ok, out} = result
  rows = Explorer.DataFrame.n_rows(out["totals"])
  IO.puts("#{label}: #{Float.round(us / 1_000_000, 2)} s, #{rows} result rows, peak #{peak.()} MB")
end

case System.argv() do
  ["gen", rows, dir] ->
    File.mkdir_p!(dir)

    {:ok, _} =
      Duck.frame("""
      COPY (SELECT i AS id, 'c' || (i % 10000) AS customer,
                   ['north','south','east','west'][1 + i % 4] AS region,
                   round(random() * 1000, 2) AS amount
            FROM range(#{rows}) t(i))
      TO #{Duck.literal(dir <> "/big.csv")} (HEADER)
      """)

    IO.puts("#{dir}/big.csv: #{div(File.stat!(dir <> "/big.csv").size, 1_048_576)} MB")

  ["explorer", dir] ->
    time.("explorer, every node", fn -> IxpipeCore.run(spec.(dir, ["customer", "region"])) end)

  ["duck", dir] ->
    time.("duckdb, final node", fn -> DuckRun.run(spec.(dir, ["customer", "region"]), only: ["totals"]) end)

  ["duck_all", dir] ->
    time.("duckdb, every node", fn -> DuckRun.run(spec.(dir, ["customer", "region"])) end)

  ["explorer_wide", dir] ->
    time.("explorer, group by id", fn -> IxpipeCore.run(spec.(dir, ["id"])) end)

  ["duck_spill", dir, limit] ->
    settings = [{"memory_limit", limit}, {"temp_directory", dir <> "/spill"}, {"preserve_insertion_order", "false"}]

    time.("duckdb, group by id, memory_limit #{limit}", fn ->
      DuckRun.run(spec.(dir, ["id"]), only: ["totals"], settings: settings)
    end)
end
