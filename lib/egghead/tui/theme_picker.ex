defmodule Egghead.TUI.ThemePicker do
  @moduledoc """
  Inline theme picker for the records and chat screens.

  A plain selection list. Same interaction shape as the
  `@`-mention / command dropdowns: arrow keys move the cursor,
  Enter applies the focused theme, Esc dismisses.

  ## Live preview

  Up/Down install the focused theme via `Egghead.Theme.set/1`
  so the screen repaints in its palette. Esc reverts to the
  theme that was active when the picker opened; Enter commits
  the current preview (and writes it to config).

  Both TUI screens hold a `%ThemePicker{}` when the picker is
  open and forward every key through `handle_key/2` until
  the status flips to `:committed` or `:cancelled`.
  """

  import Egghead.OpenTUI.View

  alias Egghead.OpenTUI.{Attrs, Colors}
  alias Egghead.Theme

  @type status :: :open | :committed | :cancelled

  @type t :: %__MODULE__{
          themes: [Theme.t()],
          filtered: [Theme.t()],
          query: String.t(),
          cursor: non_neg_integer(),
          original: String.t()
        }

  defstruct [:themes, :filtered, :query, :cursor, :original]

  @max_rows 8

  # ---- Lifecycle ----------------------------------------------------------

  @doc "Open the picker. The list is loaded once at open-time."
  @spec open() :: t()
  def open do
    themes = Theme.list()
    committed = Theme.committed_name()

    cursor =
      case Enum.find_index(themes, &(&1.name == committed)) do
        nil -> 0
        idx -> idx
      end

    %__MODULE__{
      themes: themes,
      filtered: themes,
      query: "",
      cursor: cursor,
      original: committed
    }
  end

  @doc "Apply a named theme directly without opening the picker. Persists to config."
  @spec apply(String.t()) :: :ok | {:error, term()}
  def apply(name) when is_binary(name), do: Theme.commit(name)

  # ---- Input --------------------------------------------------------------

  @spec handle_key(term(), t()) :: {t(), status()}
  def handle_key({:key, :escape}, %__MODULE__{} = picker) do
    Theme.set(picker.original)
    {picker, :cancelled}
  end

  def handle_key({:key, :enter}, %__MODULE__{} = picker) do
    case focused(picker) do
      nil ->
        Theme.set(picker.original)
        {picker, :cancelled}

      theme ->
        commit(picker, theme)
    end
  end

  def handle_key({:key, :up}, %__MODULE__{} = picker), do: move(picker, -1)
  def handle_key({:key, :down}, %__MODULE__{} = picker), do: move(picker, +1)
  def handle_key({:key, :ctrl_p}, %__MODULE__{} = picker), do: move(picker, -1)
  def handle_key({:key, :ctrl_n}, %__MODULE__{} = picker), do: move(picker, +1)

  def handle_key({:key, :backspace}, %__MODULE__{} = picker) do
    new_query =
      case String.length(picker.query) do
        0 -> ""
        n -> String.slice(picker.query, 0, n - 1)
      end

    {refilter(picker, new_query), :open}
  end

  def handle_key({:char, c}, %__MODULE__{} = picker) when is_binary(c) do
    {refilter(picker, picker.query <> c), :open}
  end

  def handle_key(_, picker), do: {picker, :open}

  # ---- View ---------------------------------------------------------------

  @doc """
  Height the picker will occupy when rendered. Screens ask for
  this so they can allocate space in their layout — same pattern
  as `dropdown_height/1` for the mention / command dropdowns.
  """
  @spec height(t()) :: non_neg_integer()
  def height(%__MODULE__{filtered: []}), do: 2
  def height(%__MODULE__{filtered: themes}), do: min(length(themes), @max_rows) + 1

  @doc """
  Render the picker as an inline dropdown of `width` columns.
  Mirrors the command-dropdown style: a single-line header, then
  one row per visible theme with the focused row in reverse-video.
  """
  @spec view(t(), pos_integer()) :: Egghead.OpenTUI.View.tree()
  def view(%__MODULE__{} = picker, width) do
    header_text =
      "  theme — ↑↓ select · enter apply · esc cancel" <>
        if picker.query != "", do: "  filter: #{picker.query}", else: ""

    header =
      text(pad_to(header_text, width),
        width: width,
        height: 1,
        fg: Colors.fg_dim(),
        bg: Colors.bg_alt(),
        attrs: Attrs.bold()
      )

    rows =
      case picker.filtered do
        [] ->
          [
            text(pad_to("  (no matches)", width),
              width: width,
              height: 1,
              fg: Colors.fg_muted(),
              bg: Colors.bg()
            )
          ]

        themes ->
          committed = Theme.committed_name()

          themes
          |> windowed(picker.cursor, @max_rows)
          |> Enum.map(fn {theme, absolute_idx} ->
            row(theme, absolute_idx == picker.cursor, theme.name == committed, width)
          end)
      end

    vbox([width: width, height: height(picker)], [header | rows])
  end

  # ---- Internals ----------------------------------------------------------

  defp row(%Theme{} = theme, focused?, committed?, width) do
    mode_badge =
      case theme.mode do
        :dark -> "·dark"
        :light -> "·light"
      end

    # Single marker: the caret marks the row whose theme is
    # currently saved in config. Focus while arrowing is carried
    # by the selection-bg highlight band alone — same as the
    # @-mention dropdown.
    prefix = if committed?, do: "▸ ", else: "  "
    label = "#{prefix}#{theme.display_name} #{mode_badge}"

    text(pad_to(label, width),
      width: width,
      height: 1,
      fg: if(focused?, do: Colors.fg(), else: Colors.accent()),
      bg: if(focused?, do: Colors.selection_bg(), else: Colors.bg())
    )
  end

  defp commit(picker, theme) do
    Theme.commit(theme.name)
    {picker, :committed}
  end

  defp move(%__MODULE__{filtered: []} = picker, _delta), do: {picker, :open}

  defp move(%__MODULE__{filtered: filtered, cursor: cursor} = picker, delta) do
    max_idx = length(filtered) - 1
    next = Kernel.max(0, Kernel.min(cursor + delta, max_idx))
    picker = %{picker | cursor: next}

    case Enum.at(filtered, next) do
      %Theme{name: name} -> Theme.set(name)
      _ -> :ok
    end

    {picker, :open}
  end

  defp refilter(%__MODULE__{themes: themes} = picker, query) do
    needle = String.downcase(query)

    filtered =
      if needle == "" do
        themes
      else
        Enum.filter(themes, fn t ->
          String.contains?(String.downcase(t.name), needle) or
            String.contains?(String.downcase(t.display_name), needle)
        end)
      end

    %{picker | query: query, filtered: filtered, cursor: 0}
  end

  defp focused(%__MODULE__{filtered: filtered, cursor: cursor}) do
    Enum.at(filtered, cursor)
  end

  # Scroll-friendly window: keep the cursor visible in `max_rows`
  # slots. Returns `[{theme, absolute_idx}]`.
  defp windowed(themes, cursor, max_rows) do
    count = length(themes)

    if count <= max_rows do
      themes |> Enum.with_index()
    else
      start = cursor |> Kernel.-(div(max_rows, 2)) |> Kernel.max(0)
      start = min(start, count - max_rows)

      themes
      |> Enum.with_index()
      |> Enum.slice(start, max_rows)
    end
  end

  defp pad_to(str, width) do
    len = String.length(str)

    if len >= width do
      String.slice(str, 0, width)
    else
      str <> String.duplicate(" ", width - len)
    end
  end
end
