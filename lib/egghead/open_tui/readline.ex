defmodule Egghead.OpenTUI.Readline do
  @moduledoc """
  Pure readline-style text editing on a `(text, cursor)` pair.

  Every function takes the current buffer (`text :: String.t()`)
  and cursor position (`cursor :: non_neg_integer()` measured in
  graphemes, not bytes) and returns a new `{text, cursor}` tuple.
  No I/O, no model, no view — just text manipulation. Any screen
  with a single-line text input field can call these functions.

  ## Cursor model

  The cursor sits *between* characters. `cursor = 0` means at the
  beginning of the buffer; `cursor = String.length(text)` means
  at the end. Insertions go *before* the character at `cursor`,
  and `delete_before/2` removes the character immediately to the
  left of the cursor.

  ## Word boundaries

  Word boundary helpers treat any of `space`, `tab`, `newline` as
  whitespace and everything else as part of a word. This matches
  the behaviour of standard readline / emacs in interactive
  shells well enough for command palettes and search fields,
  without trying to handle CJK segmentation or other niceties.

  ## Operations

    * `insert/3`              — insert a string at the cursor
    * `delete_before/2`       — backspace
    * `kill_to_eol/2`         — Ctrl+K
    * `kill_to_bol/2`         — Ctrl+U
    * `kill_word/2`           — Ctrl+W (kill previous word)
    * `kill_word_forward/2`   — Alt+D (kill next word)
    * `move_to_start/2`       — Ctrl+A
    * `move_to_end/2`         — Ctrl+E
    * `move_left/2`           — ←
    * `move_right/2`          — →
    * `move_word_left/2`      — Alt+B
    * `move_word_right/2`     — Alt+F
  """

  @type t :: {String.t(), non_neg_integer()}

  @doc "Insert `chunk` at the current cursor position."
  @spec insert(String.t(), non_neg_integer(), String.t()) :: t()
  def insert(text, cursor, chunk) when is_binary(text) and is_binary(chunk) do
    {prefix, suffix} = split(text, cursor)
    {prefix <> chunk <> suffix, cursor + String.length(chunk)}
  end

  @doc "Delete the character immediately before the cursor."
  @spec delete_before(String.t(), non_neg_integer()) :: t()
  def delete_before(text, 0), do: {text, 0}

  def delete_before(text, cursor) do
    {prefix, suffix} = split(text, cursor)
    new_prefix = String.slice(prefix, 0, cursor - 1)
    {new_prefix <> suffix, cursor - 1}
  end

  @doc "Delete from the cursor to the end of the buffer."
  @spec kill_to_eol(String.t(), non_neg_integer()) :: t()
  def kill_to_eol(text, cursor) do
    {prefix, _} = split(text, cursor)
    {prefix, cursor}
  end

  @doc "Delete from the start of the buffer to the cursor."
  @spec kill_to_bol(String.t(), non_neg_integer()) :: t()
  def kill_to_bol(text, cursor) do
    {_, suffix} = split(text, cursor)
    {suffix, 0}
  end

  @doc "Delete the word immediately before the cursor."
  @spec kill_word(String.t(), non_neg_integer()) :: t()
  def kill_word(text, 0), do: {text, 0}

  def kill_word(text, cursor) do
    {prefix, suffix} = split(text, cursor)
    new_cursor = previous_word_boundary(prefix)
    new_prefix = String.slice(prefix, 0, new_cursor)
    {new_prefix <> suffix, new_cursor}
  end

  @doc "Delete the word immediately after the cursor."
  @spec kill_word_forward(String.t(), non_neg_integer()) :: t()
  def kill_word_forward(text, cursor) do
    {prefix, suffix} = split(text, cursor)
    word_end = next_word_boundary(text, cursor)
    chars_to_drop = word_end - cursor
    new_suffix = String.slice(suffix, chars_to_drop, String.length(suffix))
    {prefix <> new_suffix, cursor}
  end

  @doc "Move the cursor to the beginning of the buffer."
  @spec move_to_start(String.t(), non_neg_integer()) :: t()
  def move_to_start(text, _cursor), do: {text, 0}

  @doc "Move the cursor to the end of the buffer."
  @spec move_to_end(String.t(), non_neg_integer()) :: t()
  def move_to_end(text, _cursor), do: {text, String.length(text)}

  @doc "Move the cursor one grapheme left."
  @spec move_left(String.t(), non_neg_integer()) :: t()
  def move_left(text, cursor), do: {text, max(cursor - 1, 0)}

  @doc "Move the cursor one grapheme right."
  @spec move_right(String.t(), non_neg_integer()) :: t()
  def move_right(text, cursor), do: {text, min(cursor + 1, String.length(text))}

  @doc "Move the cursor backward to the previous word boundary."
  @spec move_word_left(String.t(), non_neg_integer()) :: t()
  def move_word_left(text, 0), do: {text, 0}

  def move_word_left(text, cursor) do
    {prefix, _} = split(text, cursor)
    {text, previous_word_boundary(prefix)}
  end

  @doc "Move the cursor forward to the next word boundary."
  @spec move_word_right(String.t(), non_neg_integer()) :: t()
  def move_word_right(text, cursor) do
    {text, next_word_boundary(text, cursor)}
  end

  # ---- internal helpers ---------------------------------------------------

  defp split(text, cursor) do
    {String.slice(text, 0, cursor), String.slice(text, cursor, String.length(text))}
  end

  defp previous_word_boundary(prefix) do
    chars = String.graphemes(prefix)
    len = length(chars)
    skip_ws = drop_while_reverse(chars, len, &whitespace?/1)
    drop_while_reverse(chars, skip_ws, &(not whitespace?(&1)))
  end

  defp next_word_boundary(text, start) do
    chars = String.graphemes(text)
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
end
