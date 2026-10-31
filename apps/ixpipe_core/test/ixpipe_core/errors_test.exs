defmodule IxpipeCore.ErrorsTest do
  use ExUnit.Case, async: true
  alias IxpipeCore.{Context, Errors}

  # Real DuckDB messages, from the engine itself, so a DuckDB upgrade that
  # rewords one shows here.
  defp duck_error(sql) do
    ctx = Context.new()
    {:error, message} = IxpipeCore.Duck.query(ctx.db, sql)
    message
  end

  test "a missing column names it and the columns there are" do
    raw = duck_error("SELECT nope FROM (SELECT 1 AS a, 2 AS b)")
    text = Errors.humanize(raw)
    assert text =~ ~s(Column "nope" isn't in the input.)
    assert text =~ "Check the spelling"
    assert text =~ ~s("a")
  end

  test "an unknown function" do
    text = Errors.humanize(duck_error("SELECT uper('a')"))
    assert text =~ ~s(There's no function named uper.)
    assert text =~ "upper"
  end

  test "a syntax error" do
    text = Errors.humanize(duck_error("SELECT 1 +* FROM x"))
    assert text =~ "can't be read"
    assert text =~ "Check"
  end

  test "a value that can't be converted" do
    text = Errors.humanize(duck_error("SELECT CAST('abc' AS INTEGER)"))
    assert text =~ ~s(abc)
    assert text =~ "TRY_CAST"
  end

  test "a missing file" do
    text = Errors.humanize(duck_error("SELECT * FROM read_csv('/no/such.csv')"))
    assert text == "The file /no/such.csv doesn't exist. Choose a file that does."
  end

  test "values of types that don't mix" do
    text = Errors.humanize(duck_error("SELECT 1 = DATE '2024-01-01'"))
    assert text =~ "Values of type INTEGER can't be converted to DATE."
    assert text =~ "Formula"

    text = Errors.humanize(duck_error("SELECT 'a' + 1"))

    assert text ==
             "+ can't take values of types STRING, INTEGER. Add explicit casts, e.g. CAST(column AS DOUBLE)."
  end

  test "a join on a column one side lacks" do
    raw = duck_error("SELECT * FROM (SELECT 1 AS id) l JOIN (SELECT 2 AS x) r USING (nope)")

    assert Errors.humanize(raw) ==
             ~s|Column "nope" isn't in the left input. Join on columns both inputs have.|
  end

  test "anything else keeps its text, without DuckDB's prefix, and says what to do" do
    assert Errors.humanize("Invalid Input Error: boom\n\nLINE 1: x") ==
             "boom. Check the tool's settings and run again."

    assert Errors.humanize("something odd") ==
             "something odd. Check the tool's settings and run again."
  end
end
