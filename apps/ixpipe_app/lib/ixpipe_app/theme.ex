defmodule IxpipeApp.Theme do
  @moduledoc false
  use Baguette.Theme

  token(:background, light: "#ffffff", dark: "#0f172a")
  token(:foreground, light: "#0f172a", dark: "#e2e8f0")
  token(:muted, light: "#f1f5f9", dark: "#1e293b")
  token(:muted_foreground, light: "#64748b", dark: "#94a3b8")
  token(:border, light: "#e2e8f0", dark: "#334155")
  token(:primary, light: "#2563eb", dark: "#3b82f6")
  token(:primary_foreground, "#ffffff")
  token(:destructive, light: "#dc2626", dark: "#f87171")
  token(:canvas, light: "#f8fafc", dark: "#020617")
end
