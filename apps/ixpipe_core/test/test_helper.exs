# `mix test --only postgres` (or mysql, mssql) runs the tests that need a
# database server (see AGENTS.md).
ExUnit.start(exclude: [:postgres, :mysql, :mssql])
