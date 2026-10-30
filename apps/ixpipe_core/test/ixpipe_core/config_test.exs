defmodule IxpipeCore.ConfigTest do
  use ExUnit.Case, async: true
  alias IxpipeCore.Config

  defp field(type, opts \\ []),
    do: Map.merge(%{key: "k", label: "K", type: type, optional: false}, Map.new(opts))

  test "strings, paths and expressions are trimmed text" do
    for type <- [:string, :path, :expr] do
      assert Config.parse(field(type), "  a > 1 ") == {:ok, "a > 1"}
      assert Config.format(field(type), "x") == "x"
    end
  end

  test "lists are comma-separated" do
    assert Config.parse(field(:list), "id, amount ,, name") == {:ok, ["id", "amount", "name"]}
    assert Config.format(field(:list), ["id", "amount"]) == "id, amount"
  end

  test "booleans" do
    assert Config.parse(field(:bool), "true") == {:ok, true}
    assert Config.parse(field(:bool), "false") == {:ok, false}
    assert {:error, _} = Config.parse(field(:bool), "maybe")
    assert Config.format(field(:bool), true) == "true"
  end

  test "choices must be one of the options" do
    f = field(:choice, options: ["first", "last"])
    assert Config.parse(f, "last") == {:ok, "last"}
    assert Config.parse(f, "middle") == {:error, "Choose one of: first, last"}
  end

  test "integers" do
    assert Config.parse(field(:integer), " 10 ") == {:ok, 10}
    assert Config.parse(field(:integer), "1.5") == {:error, "Enter a whole number"}
    assert Config.format(field(:integer), 10) == "10"
  end

  test "formulas are one per line as name = expression" do
    text = "taxed = amount * 1.1\n\n flag = a = b "

    assert Config.parse(field(:formulas), text) ==
             {:ok,
              [%{"as" => "taxed", "expr" => "amount * 1.1"}, %{"as" => "flag", "expr" => "a = b"}]}

    assert Config.parse(field(:formulas), "amount * 2") ==
             {:error, "Write one formula per line as name = expression"}
  end

  test "aggregates are op(column) as name, comma-separated" do
    assert Config.parse(field(:aggregates), "sum(amount) as total, COUNT( id ) AS orders") ==
             {:ok,
              [
                %{"op" => "sum", "column" => "amount", "as" => "total"},
                %{"op" => "count", "column" => "id", "as" => "orders"}
              ]}

    assert Config.parse(field(:aggregates), "total = sum(amount)") ==
             {:error, "Use op(column) as name, e.g. sum(amount) as total"}

    assert Config.parse(field(:aggregates), "median(amount) as m") ==
             {:error,
              "median is not an aggregate. Use one of: sum, mean, min, max, count, n_distinct"}
  end

  test "empty text is Required, or removes an optional setting" do
    assert Config.parse(field(:list), "  ") == {:error, "Required"}
    assert Config.parse(field(:list, optional: true), "") == {:ok, nil}
    assert Config.format(field(:list), nil) == ""
  end

  test "format then parse round-trips every tool's valid config" do
    values = %{
      string: "x",
      path: "/tmp/a.csv",
      expr: "a > 1",
      list: ["a", "b"],
      bool: true,
      integer: 5,
      formulas: [%{"as" => "t", "expr" => "a * 2"}],
      aggregates: [%{"op" => "max", "column" => "a", "as" => "m"}]
    }

    for {type, value} <- values do
      f = field(type)
      assert Config.parse(f, Config.format(f, value)) == {:ok, value}, "#{type}"
    end

    f = field(:choice, options: ["inner", "left"])
    assert Config.parse(f, Config.format(f, "left")) == {:ok, "left"}
  end
end
