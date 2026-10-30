# `mix test --only postgres` (or mysql, mssql, s3) runs the tests that need a
# database server (see AGENTS.md).
ExUnit.start(exclude: [:postgres, :mysql, :mssql, :s3, :bigquery])
