defmodule Egghead.TUI.Records.Model do
  @moduledoc """
  State for the records-list screen.

  Holds the filtered record set, the cursor, the hydrated body
  and total line count for the currently selected record, the
  display toggles, and the cached terminal dimensions.

  The model owns its own width/height — the runtime dispatches
  a `{:resize, w, h}` message whenever the terminal size
  changes (including once before the first frame), and the
  reducer stores them here. Any code that needs to know the
  visible window size (scroll clamp, scrollbar geometry, list
  pagination) reads from `model.width` / `model.height`
  instead of threading dimensions through call sites.
  """

  alias Egghead.RecordStore
  alias Egghead.TUI.Records.Slug

  @type date_format :: :relative | :iso

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          filter: String.t(),
          filter_cursor: non_neg_integer(),
          selection: non_neg_integer(),
          all: [Egghead.Record.t()],
          filtered: [Egghead.Record.t()],
          selected_id: String.t() | nil,
          selected_body: String.t() | nil,
          show_all_classes: boolean(),
          date_format: date_format(),
          preview_scroll: non_neg_integer(),
          preview_total_lines: non_neg_integer()
        }

  defstruct width: 80,
            height: 24,
            filter: "",
            filter_cursor: 0,
            selection: 0,
            all: [],
            filtered: [],
            selected_id: nil,
            selected_body: nil,
            show_all_classes: false,
            date_format: :relative,
            preview_scroll: 0,
            preview_total_lines: 0

  @doc "Build the initial model by listing records from the store."
  @spec init() :: t()
  def init do
    all =
      RecordStore.list_records()
      |> Enum.sort_by(&sort_key/1, :desc)

    %__MODULE__{all: all}
    |> refilter()
    |> hydrate_selection()
  end

  # ---- transformations ----------------------------------------------------

  @doc "Update cached width and height. Called from the `:resize` handler."
  @spec set_dimensions(t(), pos_integer(), pos_integer()) :: t()
  def set_dimensions(%__MODULE__{} = model, w, h) when w > 0 and h > 0 do
    %{model | width: w, height: h}
  end

  @doc "Reload records from the store, preserving filter / selection / toggles."
  @spec reload(t(), String.t() | nil) :: t()
  def reload(%__MODULE__{} = model, prefer_id \\ nil) do
    all =
      RecordStore.list_records()
      |> Enum.sort_by(&sort_key/1, :desc)

    model = %{model | all: all} |> refilter()

    selection =
      case prefer_id && Enum.find_index(model.filtered, &(&1.id == prefer_id)) do
        nil -> 0
        idx when is_integer(idx) -> idx
      end

    %{model | selection: selection, selected_id: nil}
    |> clamp_selection()
    |> hydrate_selection()
  end

  @doc """
  Recompute `:filtered` from `:all`, the current `:filter`, and
  `:show_all_classes`.
  """
  @spec refilter(t()) :: t()
  def refilter(%__MODULE__{} = model) do
    needle = String.downcase(model.filter)

    filtered =
      model.all
      |> filter_by_class(model.show_all_classes)
      |> filter_by_query(needle)

    %{model | filtered: filtered}
  end

  defp filter_by_class(records, true), do: records

  defp filter_by_class(records, false) do
    Enum.filter(records, fn r -> r.class == :durable end)
  end

  defp filter_by_query(records, ""), do: records

  defp filter_by_query(records, needle) do
    Enum.filter(records, fn r ->
      String.contains?(String.downcase(r.id || ""), needle) or
        String.contains?(String.downcase(r.title || ""), needle)
    end)
  end

  @doc """
  Clamp the selection cursor to `[0, list_total - 1]` where
  `list_total` includes the phantom create row when present.
  """
  @spec clamp_selection(t()) :: t()
  def clamp_selection(%__MODULE__{} = model) do
    n = list_total(model)
    new_sel = if n == 0, do: 0, else: min(model.selection, n - 1)
    %{model | selection: new_sel}
  end

  @doc """
  Hydrate the body of the currently selected record. Cheap if
  the selection hasn't changed since last hydration (id check).
  Resets `:preview_scroll` to 0 whenever the selected record
  changes, and caches `:preview_total_lines` for clamp logic.
  """
  @spec hydrate_selection(t()) :: t()
  def hydrate_selection(%__MODULE__{} = model) do
    case Enum.at(model.filtered, model.selection) do
      nil ->
        %{
          model
          | selected_body: nil,
            selected_id: nil,
            preview_scroll: 0,
            preview_total_lines: 0
        }

      record ->
        if record.id == model.selected_id do
          model
        else
          {body, total_lines} =
            case RecordStore.get_record(record.id) do
              {:ok, full} ->
                b = full.body || ""
                {b, line_count(b)}

              _ ->
                {"(failed to load)", 1}
            end

          %{
            model
            | selected_body: body,
              selected_id: record.id,
              preview_scroll: 0,
              preview_total_lines: total_lines
          }
        end
    end
  end

  @doc """
  Adjust the preview scroll by `delta` lines, clamped against
  the actual visible window size derived from `model.height`.
  """
  @spec scroll_preview(t(), integer()) :: t()
  def scroll_preview(%__MODULE__{} = model, delta) do
    max_scroll = max(model.preview_total_lines - content_h(model), 0)
    new_scroll = model.preview_scroll |> Kernel.+(delta) |> max(0) |> min(max_scroll)
    %{model | preview_scroll: new_scroll}
  end

  @doc "Toggle whether the list shows only `:durable` or all classes."
  @spec toggle_class_filter(t()) :: t()
  def toggle_class_filter(%__MODULE__{} = model) do
    %{model | show_all_classes: not model.show_all_classes}
    |> refilter()
    |> clamp_selection()
    |> hydrate_selection()
  end

  @doc "Toggle the date display format between `:relative` and `:iso`."
  @spec toggle_date_format(t()) :: t()
  def toggle_date_format(%__MODULE__{date_format: :relative} = model),
    do: %{model | date_format: :iso}

  def toggle_date_format(%__MODULE__{date_format: :iso} = model),
    do: %{model | date_format: :relative}

  # ---- phantom create row ------------------------------------------------

  @doc """
  If the trimmed filter would slugify to an id that doesn't yet
  exist, return `{title, slug}`. Otherwise return `nil`. Mirrors
  `Egghead.TUI.App.creation_target/1` on `main`.
  """
  @spec creation_target(t()) :: {String.t(), String.t()} | nil
  def creation_target(%__MODULE__{} = model) do
    title = String.trim(model.filter)

    cond do
      title == "" ->
        nil

      true ->
        slug = Slug.slugify(title)

        cond do
          slug == "" -> nil
          Enum.any?(model.filtered, &(&1.id == slug)) -> nil
          true -> {title, slug}
        end
    end
  end

  @doc "Total list length, counting the phantom create row when present."
  @spec list_total(t()) :: non_neg_integer()
  def list_total(%__MODULE__{} = model) do
    base = length(model.filtered)
    if creation_target(model), do: base + 1, else: base
  end

  @doc "Index of the phantom create row (one past the end of `filtered`), or `nil`."
  @spec phantom_index(t()) :: non_neg_integer() | nil
  def phantom_index(%__MODULE__{} = model) do
    if creation_target(model), do: length(model.filtered), else: nil
  end

  @doc "True if the cursor is currently on the phantom create row."
  @spec phantom_selected?(t()) :: boolean()
  def phantom_selected?(%__MODULE__{} = model) do
    case phantom_index(model) do
      nil -> false
      idx -> idx == model.selection
    end
  end

  @doc """
  Visible content height of the preview pane (excluding label).
  Mirrors the chrome math in `Egghead.TUI.Records.View.render/1`:
  `body = h - 6`, `list_h = body / 3`, `preview_h = body - list_h`,
  `content_h = preview_h - 1`.
  """
  @spec content_h(t()) :: pos_integer()
  def content_h(%__MODULE__{height: h}) do
    body_h = max(h - 6, 1)
    list_h = max(div(body_h, 3), 1)
    preview_h = max(body_h - list_h, 1)
    max(preview_h - 1, 1)
  end

  # ---- readline-style filter editing -------------------------------------
  #
  # The search bar maintains a separate `filter_cursor` so the
  # user can move around within the input string instead of being
  # locked to the end. Editing transforms always run through one
  # of the helpers below so the cursor stays consistent and the
  # results are re-filtered (which also re-clamps the selection
  # and re-hydrates the preview).

  @doc """
  Insert `text` at the current cursor position and advance the
  cursor by its length.
  """
  @spec insert_at_cursor(t(), String.t()) :: t()
  def insert_at_cursor(%__MODULE__{} = model, text) when is_binary(text) do
    {prefix, suffix} = split_at(model.filter, model.filter_cursor)
    new_filter = prefix <> text <> suffix
    new_cursor = model.filter_cursor + String.length(text)

    model
    |> apply_filter(new_filter, new_cursor)
  end

  @doc "Delete the character immediately before the cursor (backspace)."
  @spec delete_before_cursor(t()) :: t()
  def delete_before_cursor(%__MODULE__{filter_cursor: 0} = model), do: model

  def delete_before_cursor(%__MODULE__{} = model) do
    {prefix, suffix} = split_at(model.filter, model.filter_cursor)
    new_prefix = String.slice(prefix, 0, model.filter_cursor - 1)
    new_filter = new_prefix <> suffix

    model
    |> apply_filter(new_filter, model.filter_cursor - 1)
  end

  @doc "Kill from cursor to end of line. Cursor stays put."
  @spec kill_to_eol(t()) :: t()
  def kill_to_eol(%__MODULE__{} = model) do
    {prefix, _suffix} = split_at(model.filter, model.filter_cursor)
    apply_filter(model, prefix, model.filter_cursor)
  end

  @doc "Kill from beginning of line to cursor. Cursor moves to 0."
  @spec kill_to_bol(t()) :: t()
  def kill_to_bol(%__MODULE__{} = model) do
    {_prefix, suffix} = split_at(model.filter, model.filter_cursor)
    apply_filter(model, suffix, 0)
  end

  @doc "Kill the word immediately before the cursor (Ctrl+W)."
  @spec kill_word(t()) :: t()
  def kill_word(%__MODULE__{filter_cursor: 0} = model), do: model

  def kill_word(%__MODULE__{} = model) do
    {prefix, suffix} = split_at(model.filter, model.filter_cursor)
    new_cursor = previous_word_boundary(prefix)
    new_prefix = String.slice(prefix, 0, new_cursor)

    apply_filter(model, new_prefix <> suffix, new_cursor)
  end

  @doc "Move the cursor to the beginning of the input."
  @spec move_cursor_to_start(t()) :: t()
  def move_cursor_to_start(%__MODULE__{} = model),
    do: %{model | filter_cursor: 0}

  @doc "Move the cursor to the end of the input."
  @spec move_cursor_to_end(t()) :: t()
  def move_cursor_to_end(%__MODULE__{} = model),
    do: %{model | filter_cursor: String.length(model.filter)}

  @doc "Move the cursor one character to the left."
  @spec move_cursor_left(t()) :: t()
  def move_cursor_left(%__MODULE__{} = model),
    do: %{model | filter_cursor: max(model.filter_cursor - 1, 0)}

  @doc "Move the cursor one character to the right."
  @spec move_cursor_right(t()) :: t()
  def move_cursor_right(%__MODULE__{} = model),
    do: %{model | filter_cursor: min(model.filter_cursor + 1, String.length(model.filter))}

  @doc "Move the cursor backward one word (Alt+B / Option+B)."
  @spec move_cursor_word_left(t()) :: t()
  def move_cursor_word_left(%__MODULE__{filter_cursor: 0} = model), do: model

  def move_cursor_word_left(%__MODULE__{} = model) do
    {prefix, _suffix} = split_at(model.filter, model.filter_cursor)
    %{model | filter_cursor: previous_word_boundary(prefix)}
  end

  @doc "Move the cursor forward one word (Alt+F / Option+F)."
  @spec move_cursor_word_right(t()) :: t()
  def move_cursor_word_right(%__MODULE__{} = model) do
    new_cursor = next_word_boundary(model.filter, model.filter_cursor)
    %{model | filter_cursor: new_cursor}
  end

  @doc "Kill the word immediately after the cursor (Alt+D / Option+D)."
  @spec kill_word_forward(t()) :: t()
  def kill_word_forward(%__MODULE__{} = model) do
    {prefix, suffix} = split_at(model.filter, model.filter_cursor)
    word_end = next_word_boundary(model.filter, model.filter_cursor)
    chars_to_drop = word_end - model.filter_cursor

    new_suffix = String.slice(suffix, chars_to_drop, String.length(suffix))
    apply_filter(model, prefix <> new_suffix, model.filter_cursor)
  end

  defp apply_filter(model, new_filter, new_cursor) do
    %{model | filter: new_filter, filter_cursor: new_cursor}
    |> refilter()
    |> clamp_selection()
    |> hydrate_selection()
  end

  defp split_at(str, idx) do
    {String.slice(str, 0, idx), String.slice(str, idx, String.length(str))}
  end

  # Find the position of the previous word boundary, scanning
  # left from the end of `prefix`. Skips trailing whitespace,
  # then skips word characters, returning the index just after
  # the previous boundary (i.e. where Ctrl+W should land).
  defp previous_word_boundary(prefix) do
    chars = String.graphemes(prefix)
    len = length(chars)
    skip_ws = drop_while_reverse(chars, len, &whitespace?/1)
    drop_while_reverse(chars, skip_ws, &(not whitespace?(&1)))
  end

  # Find the position of the next word boundary, scanning right
  # from `start`. Skips leading whitespace, then skips word
  # characters, returning the index just past the end of the
  # next word (i.e. where Alt+F should land).
  defp next_word_boundary(filter, start) do
    chars = String.graphemes(filter)
    len = length(chars)
    skip_ws = advance_while(chars, start, len, &whitespace?/1)
    advance_while(chars, skip_ws, len, &(not whitespace?(&1)))
  end

  defp advance_while(_chars, idx, len, _pred) when idx >= len, do: len

  defp advance_while(chars, idx, len, pred) do
    if pred.(Enum.at(chars, idx)),
      do: advance_while(chars, idx + 1, len, pred),
      else: idx
  end

  defp drop_while_reverse(_chars, 0, _pred), do: 0

  defp drop_while_reverse(chars, idx, pred) do
    if pred.(Enum.at(chars, idx - 1)),
      do: drop_while_reverse(chars, idx - 1, pred),
      else: idx
  end

  defp whitespace?(<<c::utf8>>), do: c in [?\s, ?\t, ?\n]
  defp whitespace?(_), do: false

  # ---- helpers ------------------------------------------------------------

  defp sort_key(%{updated: nil}), do: ""
  defp sort_key(%{updated: u}) when is_binary(u), do: u
  defp sort_key(_), do: ""

  defp line_count(""), do: 1
  defp line_count(body) when is_binary(body) do
    body |> String.split("\n") |> length()
  end
end
