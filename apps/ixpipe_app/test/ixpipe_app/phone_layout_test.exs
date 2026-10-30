defmodule IxpipeApp.PhoneLayoutTest do
  # Below 640px wide (a phone in portrait) the canvas gets the full width:
  # a compact header with icon-only Save and Run, a horizontally scrolling
  # ribbon, and Canvas / Properties / Results as panes of a tab bar. Wider
  # windows keep the desktop layout.
  use ExUnit.Case, async: false
  alias Baguette.Test
  alias IxpipeApp.UI

  @fixtures Path.expand("../fixtures", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-phone-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(Path.join(dir, "sales.yaml"), """
    name: sales
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
    """)

    window = System.unique_integer([:positive])

    start_supervised!(
      {IxpipeApp.MainView,
       window: window,
       theme: IxpipeApp.Theme,
       args: [dir: dir, path: Path.join(dir, "sales.yaml")]}
    )

    %{window: window, dir: dir}
  end

  defp phone(w), do: Test.resize(w, 390, 844)

  test "a wide window keeps the desktop layout: canvas, results and properties at once",
       %{window: w} do
    Test.resize(w, 1200, 800)
    assert UI.find(w, "Canvas") != []
    assert UI.find(w, "Results") != []
    assert UI.find(w, "Configuration") != []
    assert UI.find(w, "Panes") == []
    assert Test.text(w) =~ "Run workflow"
  end

  test "a phone shows one pane at a time, the canvas first", %{window: w} do
    phone(w)
    assert UI.find(w, "Canvas") != []
    assert UI.find(w, "Results") == []
    assert UI.find(w, "Configuration") == []

    Test.click(w, "Show properties")
    assert UI.find(w, "Configuration") != []
    assert UI.find(w, "Canvas") == []

    Test.click(w, "Show results")
    assert UI.find(w, "Results") != []

    Test.click(w, "Show canvas")
    assert UI.find(w, "Canvas") != []
  end

  test "on a phone, Save and Run are icon-only and still work", %{window: w, dir: dir} do
    phone(w)
    [run] = UI.find(w, "Run workflow")
    [save] = UI.find(w, "Save workflow")
    assert Enum.all?([run, save], &icon_only?/1)
    assert run["a"]["data-variant"] == "primary"

    File.rm!(Path.join(dir, "sales.yaml"))
    Test.click(w, "Save workflow")
    assert File.exists?(Path.join(dir, "sales.yaml"))
    Test.click(w, "Run workflow")
    assert Test.text(w) =~ "Run succeeded"
  end

  test "selecting a tool on a phone shows its properties", %{window: w} do
    phone(w)
    Test.click(w, "Select orders")
    assert UI.find(w, "Configuration") != []
    assert Test.text(w) =~ "Input CSV"
  end

  test "a run on a phone with a tool selected shows its results", %{window: w} do
    phone(w)
    Test.click(w, "Select orders")
    Test.click(w, "Run workflow")
    assert UI.find(w, "Results") != []
    assert Test.text(w) =~ "orders · 2 rows"
    assert Test.text(w) =~ "Run succeeded"
  end

  test "the ribbon's tabs and commands scroll sideways on a phone", %{window: w} do
    phone(w)
    [ribbon] = UI.find(w, "Ribbon")
    rows = for %{"a" => %{"class" => class}} <- ribbon["c"], do: class
    assert Enum.count(rows, &(&1 =~ "overflow-x-auto")) == 2
  end

  test "every control outside the canvas is a touch target of at least 40px", %{window: w} do
    phone(w)
    Test.click(w, "Select orders")
    assert small_controls(w) == []
    Test.click(w, "Show canvas")
    Test.click(w, "In/Out tab")
    assert small_controls(w) == []
    Test.click(w, "Workflows")
    assert small_controls(w) == []
  end

  test "the home screen and the canvas both follow the window size", %{window: w} do
    phone(w)
    Test.click(w, "Workflows")
    Test.click(w, "Open sales.yaml")
    assert UI.find(w, "Panes") != []
    Test.resize(w, 1200, 800)
    assert UI.find(w, "Panes") == []
  end

  defp icon_only?(%{"c" => children}),
    do: Enum.all?(children, &match?(%{"t" => "icon"}, &1))

  # Buttons, outside the canvas's cards (which scale with the zoom), without
  # a 40px minimum height.
  defp small_controls(w) do
    surface = UI.find(w, "Canvas surface")
    on_canvas = MapSet.new(Enum.flat_map(surface, &elements/1))

    for %{"t" => "button", "a" => attrs} = el <- elements(Test.tree(w)),
        el not in on_canvas,
        not (attrs["class"] =~ ~r/\bmin-h-10\b/),
        do: attrs["aria-label"]
  end

  defp elements(%{"c" => children} = el), do: [el | Enum.flat_map(children, &elements/1)]
  defp elements(_), do: []
end
