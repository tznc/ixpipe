# `mix test --only postgres` runs the tests that need a PostgreSQL server
# (see AGENTS.md).
#
# Script tool tests run per language (`script: "python"`, ...) when that
# runtime is installed; `:pandas` ones need pandas and pyarrow.
missing =
  for %{language: language, found: {:error, _}} <- IxpipeCore.Script.runtimes(),
      do: {:script, language}

pandas? =
  match?({_, 0}, System.cmd("python3", ["-c", "import pandas, pyarrow"], stderr_to_stdout: true))

ExUnit.start(exclude: [:postgres | missing] ++ if(pandas?, do: [], else: [:pandas]))
