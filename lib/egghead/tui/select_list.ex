defmodule Egghead.TUI.SelectList do
  @moduledoc """
  Generic inline select list.

  Pure state + view. Callers drive side effects (live preview,
  commit, revert, action dispatch) off the status events
  returned from `handle_key/2`. Used by the theme picker and
  the `/join` · `/mute` · `/unmute` · `/handoff` pickers; the
  interaction shape mirrors the `@`-mention and command-palette
  dropdowns so the TUI feels consistent.

  ### Data shape

  Items are plain maps — `%{id: String.t(), label: String.t()}`
  is the canonical form, with an optional `:hint` field for a
  dim secondary line after the label.

  ### Events

      :open                      — keep rendering
      {:cursor_moved, item}      — arrow keys moved focus to `item`
      {:committed, item}         — Enter; caller should act on `item.id`
      :cancelled                 — Esc

  Callers typically pattern-match on these in the reducer and
  run the appropriate side effect, then either keep the list or
  drop it from model state.
  """

  import Egghead.OpenTUI.View

  alias Egghead.OpenTUI.{Attrs, Colors}

  @max_rows 8

  @type item :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          optional(:hint) => String.t()
        }
  @type status :: :open | {:cursor_moved, item()} | {:committed, item()} | :cancelled

  @type t :: %__MODULE__{
          items: [item()],
          filtered: [item()],
          query: String.t(),
          cursor: non_neg_integer(),
          title: String.t(),
          hint: String.t(),
          marker_id: String.t() | nil,
          freeform_prefix: String.t() | nil
        }

  defstruct [
    :items,
    :filtered,
    :query,
    :cursor,
    :title,
    :hint,
    marker_id: nil,
    freeform_prefix: nil
  ]

  # ---- Lifecycle ----------------------------------------------------------

  @doc """
  Build a fresh select list.

  Opts:
    * `:title` — title text shown in the list header (defaults to `""`).
    * `:hint` — hint text shown after the title (defaults to
      `"↑↓ select · enter apply · esc cancel"`).
    * `:marker_id` — id of an item that should carry the `▸` caret
      in the rendered list (e.g. the "currently active" or
      "already selected" item). `nil` = no marker.
    * `:cursor_id` — id of the item to focus on open. Defaults to
      the `:marker_id` if present, otherwise index 0.
    * `:freeform_prefix` — when set, typing a query that doesn't
      exactly match any item prepends a synthetic row whose label
      is `"\#{prefix}\#{query}"` and whose id is the raw query,
      letting the user commit a new value. Used by `/join` so the
      picker doesn't hide the "create a new room" path.
  """
  @spec new([item()], keyword()) :: t()
  def new(items, opts \\ []) when is_list(items) do
    marker_id = Keyword.get(opts, :marker_id)
    cursor_id = Keyword.get(opts, :cursor_id, marker_id)

    cursor =
      case Enum.find_index(items, &(&1.id == cursor_id)) do
        nil -> 0
        idx -> idx
      end

    %__MODULE__{
      items: items,
      filtered: items,
      query: "",
      cursor: cursor,
      title: Keyword.get(opts, :title, ""),
      hint: Keyword.get(opts, :hint, "↑↓ select · enter apply · esc cancel"),
      marker_id: marker_id,
      freeform_prefix: Keyword.get(opts, :freeform_prefix)
    }
  end

  @doc "Current cursor item, or nil if the filtered list is empty."
  @spec focused(t()) :: item() | nil
  def focused(%__MODULE__{filtered: filtered, cursor: cursor}) do
    Enum.at(filtered, cursor)
  end

  # ---- Input --------------------------------------------------------------

  @spec handle_key(term(), t()) :: {t(), status()}
  def handle_key({:key, :escape}, %__MODULE__{} = list), do: {list, :cancelled}
  def handle_key({:key, :ctrl_g}, %__MODULE__{} = list), do: {list, :cancelled}

  def handle_key({:key, :enter}, %__MODULE__{} = list) do
    case focused(list) do
      nil -> {list, :cancelled}
      item -> {list, {:committed, item}}
    end
  end

  def handle_key({:key, :up}, %__MODULE__{} = list), do: move(list, -1)
  def handle_key({:key, :down}, %__MODULE__{} = list), do: move(list, +1)
  def handle_key({:key, :ctrl_p}, %__MODULE__{} = list), do: move(list, -1)
  def handle_key({:key, :ctrl_n}, %__MODULE__{} = list), do: move(list, +1)

  def handle_key({:key, :backspace}, %__MODULE__{} = list) do
    new_query =
      case String.length(list.query) do
        0 -> ""
        n -> String.slice(list.query, 0, n - 1)
      end

    {refilter(list, new_query), :open}
  end

  def handle_key({:char, c}, %__MODULE__{} = list) when is_binary(c) do
    {refilter(list, list.query <> c), :open}
  end

  def handle_key(_, list), do: {list, :open}

  # ---- View ---------------------------------------------------------------

  @doc "Height this list will occupy when rendered."
  @spec height(t()) :: non_neg_integer()
  def height(%__MODULE__{filtered: []}), do: 2
  def height(%__MODULE__{filtered: items}), do: min(length(items), @max_rows) + 1

  @doc "Render the list as an inline dropdown of `width` columns."
  @spec view(t(), pos_integer()) :: Egghead.OpenTUI.View.tree()
  def view(%__MODULE__{} = list, width) do
    header_text =
      "  #{list.title} — #{list.hint}" <>
        if list.query != "", do: "  filter: #{list.query}", else: ""

    header =
      text(pad_to(header_text, width),
        width: width,
        height: 1,
        fg: Colors.fg_dim(),
        bg: Colors.bg_alt(),
        attrs: Attrs.bold()
      )

    rows =
      case list.filtered do
        [] ->
          [
            text(pad_to("  (no matches)", width),
              width: width,
              height: 1,
              fg: Colors.fg_muted(),
              bg: Colors.bg()
            )
          ]

        items ->
          items
          |> windowed(list.cursor, @max_rows)
          |> Enum.map(fn {item, absolute_idx} ->
            row(item, absolute_idx == list.cursor, item.id == list.marker_id, width)
          end)
      end

    vbox([width: width, height: height(list)], [header | rows])
  end

  # ---- Internals ----------------------------------------------------------

  defp row(item, focused?, marked?, width) do
    prefix = if marked?, do: "▸ ", else: "  "
    hint_suffix = if Map.get(item, :hint), do: "  #{item.hint}", else: ""
    label = "#{prefix}#{item.label}#{hint_suffix}"

    text(pad_to(label, width),
      width: width,
      height: 1,
      fg: if(focused?, do: Colors.fg(), else: Colors.accent()),
      bg: if(focused?, do: Colors.selection_bg(), else: Colors.bg())
    )
  end

  defp move(%__MODULE__{filtered: []} = list, _delta), do: {list, :open}

  defp move(%__MODULE__{filtered: filtered, cursor: cursor} = list, delta) do
    max_idx = length(filtered) - 1
    next = Kernel.max(0, Kernel.min(cursor + delta, max_idx))
    list = %{list | cursor: next}

    case Enum.at(filtered, next) do
      nil -> {list, :open}
      item -> {list, {:cursor_moved, item}}
    end
  end

  defp refilter(%__MODULE__{items: items} = list, query) do
    needle = String.downcase(query)

    matches =
      if needle == "" do
        items
      else
        Enum.filter(items, fn item ->
          String.contains?(String.downcase(item.label), needle) or
            String.contains?(String.downcase(item.id), needle)
        end)
      end

    filtered = maybe_prepend_freeform(matches, list.freeform_prefix, query)
    %{list | query: query, filtered: filtered, cursor: 0}
  end

  # When `freeform_prefix` is set and the user has typed a non-
  # empty query that doesn't exactly match one of the existing
  # items, synthesize a leading row that commits the raw query.
  # Lets `/join foo-bar` create a new room even though "foo-bar"
  # isn't in the picker's catalogue.
  defp maybe_prepend_freeform(matches, nil, _query), do: matches
  defp maybe_prepend_freeform(matches, _prefix, ""), do: matches

  defp maybe_prepend_freeform(matches, prefix, query) do
    if Enum.any?(matches, &(&1.id == query)) do
      matches
    else
      [%{id: query, label: "#{prefix}#{query}"} | matches]
    end
  end

  defp windowed(items, cursor, max_rows) do
    count = length(items)

    if count <= max_rows do
      items |> Enum.with_index()
    else
      start = cursor |> Kernel.-(div(max_rows, 2)) |> Kernel.max(0)
      start = min(start, count - max_rows)

      items
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
