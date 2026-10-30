defmodule IxpipeApp.DesignRulesTest do
  # The design language (see AGENTS.md, adopted from tznc/ixtable's
  # docs/decisions/design-language.md), checked on every screen and in the
  # source, so screens built at different times look and behave alike.
  use ExUnit.Case, async: false
  alias Baguette.Test

  @fixtures Path.expand("../fixtures", __DIR__)
  @lib Path.expand("../../lib", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "ixpipe-design-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, window: System.unique_integer([:positive])}
  end

  defp start(%{dir: dir, window: window}, args \\ []) do
    start_supervised!(
      {IxpipeApp.MainView, window: window, theme: IxpipeApp.Theme, args: [dir: dir] ++ args}
    )

    window
  end

  defp seed(dir) do
    File.write!(Path.join(dir, "sales.yaml"), """
    name: sales
    nodes:
      - {id: orders, tool: input_csv, position: {x: 40, y: 40}, config: {path: #{@fixtures}/orders.csv}}
    """)
  end

  # Every screen the window can show, reached as a user would.
  defp screens(ctx) do
    seed(ctx.dir)
    w = start(ctx)
    home = frame(w)
    Test.click(w, "Open sales.yaml")
    canvas = frame(w)
    Test.click(w, "Add sort")
    Test.click(w, "Connect from orders")
    connecting = frame(w)
    Test.click(w, "Connect to sort_1 in")
    Test.click(w, "Run workflow")
    failed = frame(w)
    Test.click(w, "Remove sort_1")
    Test.click(w, "Run workflow")
    ran = frame(w)
    Test.click(w, "Save workflow")
    saved = frame(w)
    Test.click(w, "Workflows")
    Test.click(w, "New workflow")
    empty = frame(w)

    [
      home: home,
      canvas: canvas,
      connecting: connecting,
      failed: failed,
      ran: ran,
      saved: saved,
      empty: empty
    ]
  end

  defp frame(window) do
    _ = Test.text(window)
    Baguette.Host.last_frame(window)["root"]
  end

  test "the theme's accent is ixtable's teal, with white text on it" do
    tokens = IxpipeApp.Theme.tokens()
    assert tokens["primary"] == "#0DB9B6"
    assert tokens["primary-foreground"] == "#FFFFFF"
    assert tokens["link"] == "#0A7C7A"
  end

  test "every button uses a shared variant, and there is at most one primary per screen", ctx do
    for {screen, root} <- screens(ctx) do
      buttons = for %{"t" => "button"} = el <- elements(root), do: el

      untyped = for %{"a" => attrs} = b <- buttons, not Map.has_key?(attrs, "data-variant"), do: b
      assert untyped == [], "#{screen}: buttons without a variant: #{inspect(untyped)}"

      primaries = for %{"a" => %{"data-variant" => "primary"}} = b <- buttons, do: b
      assert length(primaries) <= 1, "#{screen}: #{length(primaries)} primary buttons"
    end
  end

  test "destructive actions use the danger variant", ctx do
    for {screen, root} <- screens(ctx),
        %{"t" => "button", "a" => attrs} <- elements(root),
        label = attrs["aria-label"] || "",
        String.match?(label, ~r/^(Remove|Delete|Drop|Reset)\b/) do
      assert attrs["data-variant"] == "danger", "#{screen}: #{label} is #{attrs["data-variant"]}"
    end
  end

  test "status shows as a tinted callout with its tone, never as bare text", ctx do
    screens = screens(ctx)
    assert callout(screens[:failed]) == "danger"
    assert callout(screens[:ran]) == "success"
  end

  test "every empty list or canvas has an empty state", ctx do
    w = start(ctx)
    assert Test.text(w) =~ "No workflows yet"
    Test.click(w, "New workflow")
    assert Test.text(w) =~ "Add a tool from the list on the left"
  end

  test "colours resolve to theme tokens on every screen", ctx do
    for {screen, root} <- screens(ctx) do
      theme = IxpipeApp.Theme.tokens()

      assert IxpipeApp.UI.unresolved_colours(%{"theme" => theme, "root" => root}) == [],
             "#{screen} has unresolved colours"
    end
  end

  test "text sizes and weights come only from IxpipeApp.Components" do
    offenders =
      for path <- Path.wildcard(Path.join(@lib, "**/*.ex")),
          Path.basename(path) != "components.ex",
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(
            ~r/\b(text-(xs|sm|base|lg|xl|2xl|3xl)|font-(medium|semibold|bold))\b/,
            line
          ),
          do: "#{Path.relative_to(path, @lib)}:#{n}"

    assert offenders == [],
           "use <.title>, <.section>, <.label>, <.caption>: #{inspect(offenders)}"
  end

  defp callout(root) do
    case for %{"a" => %{"data-callout" => tone}} <- elements(root), do: tone do
      [tone] -> tone
      other -> flunk("expected one callout, got #{inspect(other)}")
    end
  end

  defp elements(%{"c" => children} = el), do: [el | Enum.flat_map(children, &elements/1)]
  defp elements(_), do: []
end
