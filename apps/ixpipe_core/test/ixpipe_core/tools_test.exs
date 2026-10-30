defmodule IxpipeCore.ToolsTest do
  use ExUnit.Case, async: true
  alias IxpipeCore.Tools

  test "lookup/1 and name/1 are inverses" do
    assert Tools.lookup("sort") == Tools.Sort
    assert Tools.name(Tools.Sort) == "sort"
    assert Tools.lookup("nope") == nil
  end
end
