defmodule IxpipeApp.UI do
  @moduledoc "Reads a window's last frame the way the fuzz and view tests need."

  # Not colours: sizes and widths that share the bg-/text-/border- prefixes.
  @not_colours ~w(xs sm base lg xl 2xl 3xl left right center 2 l-2 l-4)

  @doc "Colour classes in `window` that name no theme token."
  def unresolved_colours(window) do
    %{"theme" => theme, "root" => root} = Baguette.Host.last_frame(window)

    for class <- classes(root),
        [_, value] <- [Regex.run(~r/^(?:[a-z]+:)?(?:bg|text|border|stroke)-(.+)$/, class)],
        value not in @not_colours,
        not String.starts_with?(value, "["),
        not Map.has_key?(theme, value),
        uniq: true,
        do: class
  end

  @doc "What a user can do in `window` now: `{:click, label}` and `{:drag, label}`."
  def actions(window) do
    for %{"a" => attrs} = el <- elements(Baguette.Test.tree(window)),
        {binding, kind} <- [{"phx-click", :click}, {"phx-drag", :drag}],
        Map.has_key?(attrs, binding),
        do: {kind, attrs["aria-label"] || el |> texts() |> Enum.join(" ")}
  end

  defp classes(%{"a" => attrs, "c" => children}),
    do: String.split(attrs["class"] || "") ++ Enum.flat_map(children, &classes/1)

  defp classes(_text), do: []

  defp elements(%{"c" => children} = el), do: [el | Enum.flat_map(children, &elements/1)]
  defp elements(_), do: []

  defp texts(text) when is_binary(text), do: [text]
  defp texts(%{"c" => children}), do: Enum.flat_map(children, &texts/1)
end
