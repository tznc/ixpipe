defmodule IxpipeCore.BrowseTest do
  # Browsing a run's table, as Alteryx's Browse tool does: pages of rows in
  # any order, and a profile of every column. All of it is SQL on the table.
  use ExUnit.Case, async: true
  alias IxpipeCore.{Context, Profile, Table}

  setup do
    ctx = Context.new()

    t =
      Table.new(ctx.db, "t",
        n: Enum.to_list(1..120),
        city: Enum.map(1..120, &if(rem(&1, 3) == 0, do: "Oslo", else: "Rome")),
        score: Enum.map(1..120, &if(&1 <= 20, do: nil, else: &1 / 2)),
        day: Enum.map(1..120, &Date.add(~D[2026-01-01], &1))
      )

    %{t: t}
  end

  test "schema lists columns with their types, in order", %{t: t} do
    assert Table.schema(t) == [
             {"n", "BIGINT"},
             {"city", "VARCHAR"},
             {"score", "DOUBLE"},
             {"day", "DATE"}
           ]
  end

  test "page reads any slice of the rows", %{t: t} do
    {columns, rows} = Table.page(t, offset: 50, limit: 50)
    assert columns == ["n", "city", "score", "day"]
    assert length(rows) == 50
    assert hd(hd(rows)) == 51
    {_, rows} = Table.page(t, offset: 100, limit: 50)
    assert length(rows) == 20
  end

  test "page sorts by a column, either way, with NULLs last", %{t: t} do
    {_, [[120 | _] | _]} = Table.page(t, limit: 1, sort: {"n", :desc})
    {_, rows} = Table.page(t, limit: 120, sort: {"score", :asc})
    assert hd(rows) |> Enum.at(2) == 10.5
    assert List.last(rows) |> Enum.at(2) == nil
  end

  test "a profile of every column", %{t: t} do
    [n, city, score, day] = Profile.columns(t)

    assert %{name: "n", type: "BIGINT", count: 120, nulls: 0, distinct: 120, min: 1, max: 120} =
             n

    assert length(n.bins) == 10
    assert Enum.sum(n.bins) == 120

    assert %{name: "city", nulls: 0, distinct: 2, min: nil, max: nil} = city
    assert city.top == [{"Rome", 80}, {"Oslo", 40}]
    assert city.bins == []

    assert %{nulls: 20, distinct: 100, min: 10.5, max: 60.0} = score
    assert Enum.sum(score.bins) == 100

    assert %{min: ~D[2026-01-02], max: ~D[2026-05-01], top: [], bins: []} = day
  end

  test "a column of one value, and an empty table, profile without errors" do
    ctx = Context.new()
    [%{bins: [3], min: 7, max: 7}] = Profile.columns(Table.new(ctx.db, "one", x: [7, 7, 7]))
    empty = Table.sql(ctx.db, "e", "SELECT 1::BIGINT AS x, 'a' AS s WHERE false")
    [%{count: 0, nulls: 0, distinct: 0, bins: []}, %{top: []}] = Profile.columns(empty)
  end
end
