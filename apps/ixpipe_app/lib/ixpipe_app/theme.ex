defmodule IxpipeApp.Theme do
  @moduledoc """
  The design language's colours (AGENTS.md), shared with ixtable: gpui-kit's
  default greys plus one accent, the app icon's teal. Colour carries meaning
  (selection, status, danger) and is never decoration.
  """
  use Baguette.Theme

  # Greys (gpui-kit's default light and dark themes).
  token(:background, light: "#FFFFFF", dark: "#0A0A0A")
  token(:foreground, light: "#0A0A0A", dark: "#FAFAFA")
  token(:muted, light: "#F5F5F5", dark: "#262626")
  token(:muted_foreground, light: "#737373", dark: "#A3A3A3")
  token(:border, light: "#E5E5E5", dark: "#262626")
  token(:sidebar, light: "#FAFAFA", dark: "#0A0A0A")
  token(:canvas, light: "#FAFAFA", dark: "#0A0A0A")

  # The one accent: selection, focus, the primary button, links.
  token(:primary, "#0DB9B6")
  token(:primary_foreground, "#FFFFFF")
  token(:link, light: "#0A7C7A", dark: "#0DB9B6")

  # Status, shown as a tint plus text, never as text colour alone. Warning
  # text is darkened to read on white.
  token(:success, light: "#22C55E", dark: "#4ADE80")
  token(:warning, light: "#EAB308", dark: "#FACC15")
  token(:warning_foreground, light: "#A16207", dark: "#FACC15")
  token(:danger, light: "#EF4444", dark: "#F87171")
end
