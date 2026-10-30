defmodule IxpipeCore.ToolsTest do
  use ExUnit.Case, async: true
  alias IxpipeCore.Tools

  @types [:string, :path, :list, :bool, :choice, :integer, :expr, :formulas, :aggregates, :select]

  test "lookup/1 and name/1 are inverses" do
    assert Tools.lookup("sort") == Tools.Sort
    assert Tools.name(Tools.Sort) == "sort"
    assert Tools.lookup("nope") == nil
  end

  test "every tool describes its settings" do
    for name <- Tools.names(), tool = Tools.lookup(name) do
      fields = tool.fields()
      keys = Enum.map(fields, & &1.key)
      assert keys == Enum.uniq(keys), "#{name} repeats a key"

      for field <- fields do
        assert is_binary(field.key) and is_binary(field.label), "#{name}: #{inspect(field)}"
        assert field.type in @types, "#{name}: #{inspect(field.type)}"
        if field.type == :choice, do: assert(field.options != [])
      end
    end
  end

  test "required/1 is the non-optional fields" do
    assert Tools.required(Tools.Sort) == ["by"]
    assert Tools.required(Tools.Join) == ["on"]
    assert Tools.required(Tools.Summarize) == ["group_by", "aggregates"]
    assert Tools.required(Tools.Unique) == []
    assert Tools.required(Tools.Union) == []
    assert Tools.required(Tools.Sample) == ["n"]
  end

  test "the new tools are registered" do
    assert Tools.lookup("union") == Tools.Union
    assert Tools.lookup("sample") == Tools.Sample
    assert Tools.lookup("unique") == Tools.Unique
    assert "union" in Tools.names()
  end
end
