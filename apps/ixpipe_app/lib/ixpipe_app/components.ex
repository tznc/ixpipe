defmodule IxpipeApp.Components do
  @moduledoc """
  The shared components of the design language (AGENTS.md). Screens compose
  these; a one-off style is a bug. Text sizes and weights live only here
  (tested in `design_rules_test.exs`).
  """
  use Phoenix.Component

  ## Type scale: five steps. Colour stays with the caller.

  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  @doc "The page title: one per view."
  def title(assigns),
    do: ~H"""
    <text class={"text-xl font-semibold " <> @class}>{render_slot(@inner_block)}</text>
    """

  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  @doc "Card, dialog and panel-section titles."
  def section(assigns),
    do: ~H"""
    <text class={"text-base font-semibold " <> @class}>{render_slot(@inner_block)}</text>
    """

  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  @doc "Content."
  def body(assigns),
    do: ~H"""
    <text class={"text-sm " <> @class}>{render_slot(@inner_block)}</text>
    """

  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  @doc "Field labels, column headers, nav headings."
  def label(assigns),
    do: ~H"""
    <text class={"text-sm font-medium text-muted-foreground " <> @class}>{render_slot(@inner_block)}</text>
    """

  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  @doc "Hints, counts, timestamps."
  def caption(assigns),
    do: ~H"""
    <text class={"text-xs text-muted-foreground " <> @class}>{render_slot(@inner_block)}</text>
    """

  ## Buttons

  @variants %{
    primary: "bg-primary text-primary-foreground hover:opacity-90",
    secondary: "border border-border bg-background hover:bg-muted",
    quiet: "hover:bg-muted",
    danger: "border border-danger text-danger hover:bg-danger/12",
    link: "text-link hover:opacity-80"
  }

  attr(:variant, :atom, default: :secondary, values: Map.keys(@variants))
  attr(:size, :atom, default: :md, values: [:sm, :md, :touch])
  attr(:class, :string, default: "")
  attr(:icon, :string, default: nil, doc: "a lucide icon name, drawn before the label")
  attr(:rest, :global, include: ~w(type disabled accept default-name title))
  slot(:inner_block)

  @doc """
  A button. `:primary` is the action that completes the task, at most one
  per view; `:secondary` is everything else; `:quiet` is for dense toolbars
  and lists; `:danger` is for delete, remove, drop and reset; `:link` for
  navigation such as breadcrumbs. Label it with a verb and an object.
  `size: :touch` is the phone size: at least 40px each way.
  An `icon` (lucide, as in ixtable) goes before the label, in its colour; an
  icon-only button needs an `aria-label`. `title` is a tooltip, such as the
  command's shortcut.
  """
  def button(assigns) do
    assigns = assign(assigns, :look, Map.fetch!(@variants, assigns.variant))

    ~H"""
    <button data-variant={@variant}
      class={"flex-row items-center gap-1 rounded-md cursor-pointer disabled:opacity-40 #{size(@size)} #{@look} #{@class}"}
      {@rest}><icon :if={@icon} name={@icon} class="size-4" />{render_slot(@inner_block)}</button>
    """
  end

  defp size(:sm), do: "px-2 py-1 text-xs font-medium"
  defp size(:md), do: "px-3 py-1 text-sm font-medium"
  defp size(:touch), do: "min-h-10 min-w-10 justify-center px-3 text-sm font-medium"

  ## Ribbon

  attr(:tabs, :list, required: true, doc: "`{key, label}` pairs")
  attr(:selected, :string, required: true)
  attr(:event, :string, default: "ribbon")
  attr(:touch, :boolean, default: false, doc: "phone size: 40px tabs")
  slot(:inner_block, required: true)

  @doc """
  The ribbon (as in ixtable, after Access): a row of tabs over the selected
  tab's labelled command groups (`ribbon_group/1`). Tabs are labelled
  "<Label> tab" and send `event` with `phx-value-tab`. Both rows scroll
  sideways when the window is too narrow for them. On a desktop the
  commands keep room for two rows of buttons on every tab, so switching
  tabs never moves the canvas.
  """
  def ribbon(assigns) do
    ~H"""
    <div class="flex-col w-full bg-sidebar" aria-label="Ribbon">
      <div class="flex-row items-center gap-1 px-2 pt-1 overflow-x-auto" role="tablist">
        <button :for={{key, label} <- @tabs} data-variant="tab" role="tab" aria-selected={to_string(key == @selected)}
          aria-label={"#{label} tab"} phx-click={@event} phx-value-tab={key}
          class={"#{tab_size(@touch)} rounded-md cursor-pointer text-xs " <> tab_look(key == @selected)}>{label}</button>
      </div>
      <div class={"flex-row items-stretch px-2 py-1 overflow-x-auto" <> if(@touch, do: "", else: " min-h-[90px]")}>{render_slot(@inner_block)}</div>
      <div class="h-px w-full bg-border" />
    </div>
    """
  end

  defp tab_size(false), do: "px-2 py-1"
  defp tab_size(true), do: "min-h-10 flex-row items-center px-3"

  defp tab_look(true), do: "font-semibold text-link bg-primary/12"
  defp tab_look(false), do: "font-medium text-muted-foreground hover:bg-muted"

  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  @doc """
  One labelled group of ribbon commands (quiet small buttons), its name a
  caption beneath them and a rule after it.
  """
  def ribbon_group(assigns) do
    ~H"""
    <div class="flex-row items-stretch">
      <div class="flex-col justify-between gap-1 px-2" role="group" aria-label={@label}>
        <div class="flex-row items-center gap-1">{render_slot(@inner_block)}</div>
        <.caption class="w-full text-center">{@label}</.caption>
      </div>
      <div class="w-px bg-border" />
    </div>
    """
  end

  attr(:tabs, :list, required: true, doc: "`{key, label}` pairs")
  attr(:selected, :string, required: true)
  attr(:event, :string, required: true)
  attr(:touch, :boolean, default: false, doc: "phone size: 40px tabs")

  @doc """
  A panel's tabs, as the ribbon's: each labelled "<Label> tab", sending
  `event` with `phx-value-tab`; the selected one takes the teal tint.
  """
  def tabs(assigns),
    do: ~H"""
    <div class="flex-row items-center gap-1" role="tablist">
      <button :for={{key, label} <- @tabs} data-variant="tab" role="tab" aria-selected={to_string(key == @selected)}
        aria-label={"#{label} tab"} phx-click={@event} phx-value-tab={key}
        class={"#{tab_size(@touch)} rounded-md cursor-pointer text-sm " <> tab_look(key == @selected)}>{label}</button>
    </div>
    """

  attr(:tabs, :list, required: true, doc: "`{key, label}` pairs")
  attr(:selected, :string, required: true)
  attr(:event, :string, required: true)
  attr(:label, :string, required: true)

  @doc """
  A phone's pane switcher, across the bottom of the window: equal tabs,
  each labelled "Show <label>" and sending `event` with `phx-value-pane`.
  The selected tab takes the selection's teal tint.
  """
  def tab_bar(assigns),
    do: ~H"""
    <div class="flex-col w-full bg-sidebar">
      <div class="h-px w-full bg-border" />
      <div class="flex-row items-center gap-1 p-1" role="tablist" aria-label={@label}>
        <button :for={{key, label} <- @tabs} data-variant="tab" role="tab" aria-selected={to_string(key == @selected)}
          aria-label={"Show #{String.downcase(label)}"} phx-click={@event} phx-value-pane={key}
          class={"flex-1 min-h-10 flex-row items-center justify-center rounded-md cursor-pointer text-sm " <> tab_look(key == @selected)}>{label}</button>
      </div>
    </div>
    """

  attr(:rest, :global, include: ~w(title))
  slot(:inner_block, required: true)

  @doc """
  A row of a list that acts when chosen, such as a message that selects
  its tool: full width, its content wrapping, a muted hover. Give it
  `phx-click` and an `aria-label`. For a command, use `button/1`.
  """
  def list_item(assigns),
    do: ~H"""
    <div role="button" class="flex-row items-start gap-2 w-full min-w-0 px-2 py-1 rounded-md cursor-pointer hover:bg-muted"
      {@rest}>{render_slot(@inner_block)}</div>
    """

  ## Status

  attr(:tone, :atom, required: true, values: [:info, :success, :warning, :danger])
  attr(:title, :string, required: true)
  attr(:class, :string, default: "")
  slot(:inner_block)

  @doc """
  A tinted callout: a tone mark, a one-line title, then what to do. Errors
  read "what happened. what to do."
  """
  def callout(assigns) do
    assigns = assign(assigns, :colour, tone_colour(assigns.tone))

    ~H"""
    <div data-callout={@tone}
      class={"flex-row items-start gap-2 p-3 rounded-md border border-#{@colour} bg-#{@colour}/12 #{@class}"}>
      <div class={"size-2 mt-1 rounded-full bg-#{@colour}"} />
      <div class="flex-col flex-1 min-w-0 gap-1">
        <text class="text-sm font-semibold text-foreground">{@title}</text>
        <text :if={@inner_block != []} class="text-sm text-foreground">{render_slot(@inner_block)}</text>
      </div>
    </div>
    """
  end

  attr(:tone, :atom, default: :neutral, values: [:neutral, :success, :warning, :danger])
  slot(:inner_block, required: true)

  @doc "A pill from one fixed vocabulary per domain."
  def status_badge(assigns) do
    assigns = assign(assigns, :colour, tone_colour(assigns.tone))

    ~H"""
    <div data-badge={@tone} class={"px-2 rounded-full bg-#{@colour}/12"}>
      <text class="text-xs text-foreground">{render_slot(@inner_block)}</text>
    </div>
    """
  end

  defp tone_colour(:info), do: "primary"
  defp tone_colour(:neutral), do: "muted-foreground"
  defp tone_colour(tone), do: Atom.to_string(tone)

  ## Layout pieces

  attr(:title, :string, required: true)
  slot(:inner_block, required: true)
  slot(:action)

  @doc "What an empty list or canvas shows: a title, one sentence, at most one action."
  def empty_state(assigns),
    do: ~H"""
    <div class="flex-col items-center gap-2 p-6">
      <text class="text-base font-semibold text-foreground">{@title}</text>
      <text class="text-sm text-muted-foreground">{render_slot(@inner_block)}</text>
      {render_slot(@action)}
    </div>
    """

  attr(:crumbs, :list,
    required: true,
    doc: "`{label, event}` pairs, then the current item's label"
  )

  attr(:touch, :boolean, default: false, doc: "phone size: 40px links")

  @doc "Drill-in navigation: earlier crumbs are links, the last is plain text."
  def breadcrumb(assigns) do
    {links, [current]} = Enum.split(assigns.crumbs, -1)
    assigns = assign(assigns, links: links, current: current)

    ~H"""
    <div class="flex-row items-center gap-1">
      <div :for={{label, event} <- @links} class="flex-row items-center gap-1">
        <.button variant={:link} size={:sm} class={if @touch, do: "px-0 min-h-10", else: "px-0"} phx-click={event}
          aria-label={label}>{label}</.button>
        <text class="text-xs text-muted-foreground">/</text>
      </div>
      <text class="text-xs text-muted-foreground">{@current}</text>
    </div>
    """
  end

  attr(:message, :string, required: true)

  @doc "A transient success note, top right; it never moves the layout."
  def toast(assigns),
    do: ~H"""
    <div data-toast="success"
      class="absolute right-[16px] top-[16px] flex-row items-center gap-2 p-3 rounded-md border border-border bg-background shadow-md">
      <div class="size-2 rounded-full bg-success" />
      <text class="text-sm text-foreground">{@message}</text>
    </div>
    """
end
