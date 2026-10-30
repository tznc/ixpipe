# `mix test --only postgres` runs the tests that need a PostgreSQL server
# (see AGENTS.md).
ExUnit.start(exclude: [:postgres])
