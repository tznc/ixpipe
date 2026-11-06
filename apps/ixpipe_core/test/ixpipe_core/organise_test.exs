defmodule IxpipeCore.OrganiseTest do
  # Containers, comments, annotations and disabled tools: how a workflow is
  # organised on the canvas, saved in YAML and honoured by a run.
  use ExUnit.Case, async: true
  alias IxpipeCore.{Edit, Spec, Table}

  @fixtures Path.expand("../fixtures", __DIR__)

  @yaml """
  name: sales
  nodes:
    - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
    - {id: sorted, tool: sort, position: {x: 300, y: 40}, inputs: {in: orders}, config: {by: [amount]}}
    - {id: top, tool: sample, position: {x: 560, y: 40}, inputs: {in: sorted}, config: {n: 2}}
    - {id: slim, tool: select, position: {x: 300, y: 240}, inputs: {in: orders}, config: {columns: [id]}}
  """

  defp spec!(yaml \\ @yaml) do
    {:ok, spec} = Spec.decode(yaml)
    spec
  end

  defp node(spec, id), do: Enum.find(spec.nodes, &(&1.id == id))
  defp container(spec, id), do: Enum.find(spec.containers, &(&1.id == id))

  describe "YAML" do
    test "a workflow without organisation loads with none" do
      spec = spec!()
      assert spec.containers == [] and spec.comments == []
      assert Enum.all?(spec.nodes, &(&1.disabled == false and &1.annotation == nil))
      refute Spec.to_yaml(spec) =~ "containers"
      refute Spec.to_yaml(spec) =~ "disabled"
    end

    test "containers, comments, annotations and disabled tools round-trip" do
      spec =
        spec!(
          @yaml <>
            """
            containers:
              - {id: prep, title: Prepare, position: {x: 20, y: 0}, nodes: [orders, sorted], collapsed: true, disabled: true}
            comments:
              - {id: note, text: "Orders arrive daily", position: {x: 40, y: 400}}
            """
        )

      assert %Spec.Container{
               title: "Prepare",
               nodes: ["orders", "sorted"],
               collapsed: true,
               disabled: true,
               position: %{"x" => 20, "y" => 0}
             } = container(spec, "prep")

      assert [%Spec.Comment{id: "note", text: "Orders arrive daily"}] = spec.comments

      spec = %{
        spec
        | nodes: Enum.map(spec.nodes, &%{&1 | disabled: &1.id == "top", annotation: "Top 2"})
      }

      assert {:ok, ^spec} = spec |> Spec.to_yaml() |> Spec.decode()
    end

    test "ids are unique across tools, containers and comments" do
      assert {:error, {:duplicate_id, "orders"}} =
               Spec.decode(@yaml <> "comments: [{id: orders, text: x}]")
    end

    test "a container holds only tools that exist, each in one container" do
      assert {:error, {:unknown_member, "box", "nope"}} =
               Spec.decode(@yaml <> "containers: [{id: box, nodes: [nope]}]")

      assert {:error, {:duplicate_member, "b", "orders"}} =
               Spec.decode(
                 @yaml <> "containers: [{id: a, nodes: [orders]}, {id: b, nodes: [orders]}]"
               )

      assert Spec.format_error({:unknown_member, "box", "nope"}) ==
               "box: holds nope, which is not a tool"
    end
  end

  describe "disabled tools" do
    test "a disabled tool and everything downstream of it are skipped" do
      spec = Edit.set_disabled(spec!(), "sorted", true)
      assert Spec.skipped(spec) == ["sorted", "top"]
    end

    test "a disabled container skips its tools and their downstream" do
      spec =
        spec!()
        |> Edit.add_container(%{"x" => 0, "y" => 0}, ["sorted"])
        |> Edit.set_disabled("container_1", true)

      assert Spec.skipped(spec) == ["sorted", "top"]
    end

    test "a run skips them instead of failing, and validation ignores their config" do
      {:ok, spec} =
        spec!()
        |> Edit.add_node("filter", %{"x" => 0, "y" => 0})
        |> Edit.connect("top", "filter_1", "in")
        |> Edit.set_disabled("sorted", true)
        |> Spec.validate()

      assert {:ok, results} = IxpipeCore.run(spec)
      assert Map.keys(results) |> Enum.sort() == ["orders", "slim"]
      assert Table.count(results["slim"]) == 4
    end

    test "execute/2 marks them skipped, with an info message saying why" do
      {:ok, spec} =
        spec!()
        |> Edit.add_container(%{"x" => 0, "y" => 0}, ["slim"])
        |> Edit.set_text("container_1", "Columns")
        |> Edit.set_disabled("container_1", true)
        |> Edit.set_disabled("sorted", true)
        |> Spec.validate()

      run = IxpipeCore.execute(spec)
      assert run.status == :ok

      assert run.nodes == %{
               "orders" => :ok,
               "sorted" => :skipped,
               "top" => :skipped,
               "slim" => :skipped
             }

      assert Enum.sort(run.disabled) == ["slim", "sorted", "top"]
      assert Map.keys(run.tables) == ["orders"]

      why = fn id -> for %{node: ^id, level: :info, text: t} <- run.messages, do: t end
      assert [sorted] = why.("sorted")
      assert sorted =~ "Skipped: disabled."
      assert [slim] = why.("slim")
      assert slim =~ "Skipped: in disabled container Columns."
      assert [top] = why.("top")
      assert top =~ "Skipped: after sorted, which is disabled."
      # Not the wording of a tool skipped because one upstream failed.
      refute Enum.any?(run.messages, &(&1.text =~ "failed"))
    end

    test "a run with every tool disabled succeeds with no results" do
      spec = Enum.reduce(~w(orders), spec!(), &Edit.set_disabled(&2, &1, true))
      {:ok, spec} = Spec.validate(spec)
      assert IxpipeCore.run(spec) == {:ok, %{}}
    end
  end

  describe "Edit" do
    test "add_container/3 holds the given tools, with a fresh id and title" do
      spec = Edit.add_container(spec!(), %{"x" => 10, "y" => 10}, ["orders"])

      assert %Spec.Container{id: "container_1", title: "Container 1", nodes: ["orders"]} =
               container(spec, "container_1")

      spec = Edit.add_container(spec, %{"x" => 10, "y" => 10}, ["orders"])
      # A tool is in one container: the newest takes it.
      assert container(spec, "container_1").nodes == []
      assert container(spec, "container_2").nodes == ["orders"]
    end

    test "add_node/4 creates a tool inside a container" do
      spec =
        spec!()
        |> Edit.add_container(%{"x" => 0, "y" => 0}, [])
        |> Edit.add_node("sort", %{"x" => 5, "y" => 5}, "container_1")

      assert container(spec, "container_1").nodes == ["sort_1"]
    end

    test "contain/3 moves a tool between containers, nil takes it out" do
      spec =
        spec!()
        |> Edit.add_container(%{"x" => 0, "y" => 0}, ["orders"])
        |> Edit.add_container(%{"x" => 0, "y" => 0}, [])
        |> Edit.contain("orders", "container_2")

      assert container(spec, "container_1").nodes == []
      assert container(spec, "container_2").nodes == ["orders"]
      spec = Edit.contain(spec, "orders", nil)
      assert container(spec, "container_2").nodes == []
    end

    test "move/4 moves a container with its tools, and a comment" do
      spec =
        spec!()
        |> Edit.add_container(%{"x" => 20, "y" => 20}, ["orders", "sorted"])
        |> Edit.add_comment(%{"x" => 0, "y" => 300})
        |> Edit.move("container_1", 10, 5)
        |> Edit.move("comment_1", 7, -500)

      assert container(spec, "container_1").position == %{"x" => 30, "y" => 25}
      assert node(spec, "orders").position == %{"x" => 50, "y" => 45}
      assert node(spec, "sorted").position == %{"x" => 310, "y" => 45}
      assert node(spec, "top").position == %{"x" => 560, "y" => 40}
      assert hd(spec.comments).position == %{"x" => 7, "y" => 0}
    end

    test "move/4 never pushes a container's tools off the canvas" do
      spec =
        spec!()
        |> Edit.add_container(%{"x" => 20, "y" => 20}, ["orders", "sorted"])
        |> Edit.move("container_1", -100, -100)

      # The container's own corner reaches the origin first.
      assert node(spec, "orders").position == %{"x" => 20, "y" => 20}
      assert node(spec, "sorted").position == %{"x" => 280, "y" => 20}
      assert container(spec, "container_1").position == %{"x" => 0, "y" => 0}
    end

    test "set_text/3 titles a container and writes a comment" do
      spec =
        spec!()
        |> Edit.add_container(%{"x" => 0, "y" => 0}, [])
        |> Edit.add_comment(%{"x" => 0, "y" => 0})
        |> Edit.set_text("container_1", "Prepare")
        |> Edit.set_text("comment_1", "Daily orders")

      assert container(spec, "container_1").title == "Prepare"
      assert hd(spec.comments).text == "Daily orders"
    end

    test "set_collapsed/3, set_disabled/3 and set_annotation/3" do
      spec =
        spec!()
        |> Edit.add_container(%{"x" => 0, "y" => 0}, ["orders"])
        |> Edit.set_collapsed("container_1", true)
        |> Edit.set_disabled("top", true)
        |> Edit.set_annotation("top", "  Top 2  ")

      assert container(spec, "container_1").collapsed
      assert node(spec, "top").disabled
      assert node(spec, "top").annotation == "Top 2"
      assert Edit.set_annotation(spec, "top", " ") |> node("top") |> Map.get(:annotation) == nil
    end

    test "remove/3 drops a container and keeps its tools, or drops them too" do
      spec = Edit.add_container(spec!(), %{"x" => 0, "y" => 0}, ["orders", "sorted"])

      kept = Edit.remove(spec, "container_1")
      assert kept.containers == []
      assert length(kept.nodes) == 4

      gone = Edit.remove(spec, "container_1", with_tools: true)
      assert Enum.map(gone.nodes, & &1.id) == ["top", "slim"]
      assert node(gone, "top").inputs == %{}
    end

    test "removing a tool takes it out of its container, and comments go too" do
      spec =
        spec!()
        |> Edit.add_container(%{"x" => 0, "y" => 0}, ["orders"])
        |> Edit.add_comment(%{"x" => 0, "y" => 0})
        |> Edit.remove_node("orders")
        |> Edit.remove("comment_1")

      assert container(spec, "container_1").nodes == []
      assert spec.comments == []
    end
  end

  test "summary/1 describes a tool's settings for an annotation" do
    assert spec!() |> node("sorted") |> IxpipeCore.Config.summary() == "Sort by: amount"
    assert spec!() |> node("top") |> IxpipeCore.Config.summary() =~ "2"
  end
end
