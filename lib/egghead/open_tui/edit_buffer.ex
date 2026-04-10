defmodule Egghead.OpenTUI.EditBuffer do
  @moduledoc """
  Pure functional multi-line text buffer with first-class
  inline object cells.

  Each row is a list of *cells*. A cell is either a single
  grapheme (a `String.t()` of length 1) or an opaque struct
  representing an atomic non-rune inline object. Cursor and
  editing operations treat every cell as exactly one column,
  so an inline object feels atomic to the user: one Backspace
  removes it, one Right Arrow steps over it, kill commands
  snap to its boundaries.

  Inline object cells are expanded back to text by `to_text/1`
  via the `:full_text` field on the struct, so downstream
  serialisation receives the verbatim content rather than any
  short display form the renderer may have used.

  All operations are pure: no I/O, no view, no side effects.
  """

  defstruct lines: [[]], row: 0, col: 0

  @type cell :: String.t() | struct()

  @type t :: %__MODULE__{
          lines: [[cell()]],
          row: non_neg_integer(),
          col: non_neg_integer()
        }

  # ---- construction --------------------------------------------------------

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Build a buffer from a string. Splits on `\\n`. Cursor lands at
  the end of the buffer (parity with how a freshly-pasted block
  feels).
  """
  @spec from_text(String.t()) :: t()
  def from_text(""), do: new()

  def from_text(text) when is_binary(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.graphemes/1)

    last = List.last(lines)
    %__MODULE__{lines: lines, row: length(lines) - 1, col: length(last)}
  end

  @doc """
  Serialise the buffer to a flat string. Grapheme cells are
  joined as-is. Inline object cells expand to their `:full_text`,
  so the caller sees the original payload rather than any short
  display form.
  """
  @spec to_text(t()) :: String.t()
  def to_text(%__MODULE__{lines: lines}) do
    lines |> Enum.map(&line_to_text/1) |> Enum.join("\n")
  end

  defp line_to_text(cells), do: cells |> Enum.map(&cell_to_text/1) |> Enum.join()

  defp cell_to_text(cell) when is_binary(cell), do: cell
  defp cell_to_text(%{__struct__: _, full_text: text}), do: text

  @spec clear(t()) :: t()
  def clear(_), do: new()

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{lines: [[]]}), do: true
  def empty?(_), do: false

  @spec cursor(t()) :: {non_neg_integer(), non_neg_integer()}
  def cursor(%__MODULE__{row: r, col: c}), do: {r, c}

  @spec line_count(t()) :: pos_integer()
  def line_count(%__MODULE__{lines: lines}), do: length(lines)

  @doc """
  Number of cells in the given line. An inline object cell
  counts as 1.
  """
  @spec line_width(t(), non_neg_integer()) :: non_neg_integer()
  def line_width(%__MODULE__{lines: lines}, row) do
    case Enum.at(lines, row) do
      nil -> 0
      cells -> length(cells)
    end
  end

  @doc """
  Return the raw cell list for `row`. Used by the renderer.
  """
  @spec line_cells(t(), non_neg_integer()) :: [cell()]
  def line_cells(%__MODULE__{lines: lines}, row), do: Enum.at(lines, row, [])

  @doc """
  Total visual rows the buffer would occupy when soft-wrapped to
  `width` columns. Each logical line contributes `ceil(len/width)`
  visual rows (minimum 1 for empty lines).
  """
  @spec visual_line_count(t(), pos_integer()) :: pos_integer()
  def visual_line_count(%__MODULE__{lines: lines}, width) when width > 0 do
    Enum.reduce(lines, 0, fn cells, acc ->
      n = length(cells)
      acc + if(n == 0, do: 1, else: ceil_div(n, width))
    end)
  end

  @doc """
  Chunk a cell list into visual rows of at most `width` cells.
  Returns `[[cell()]]` — at least one chunk even for empty input.
  """
  @spec wrap_cells([cell()], pos_integer()) :: [[cell()]]
  def wrap_cells(cells, width) when width > 0 do
    case Enum.chunk_every(cells, width) do
      [] -> [[]]
      chunks -> chunks
    end
  end

  defp ceil_div(n, d), do: div(n + d - 1, d)

  # ---- insertion -----------------------------------------------------------

  @doc """
  Insert text at the cursor. Embedded `\\n` characters are
  honored: each one splits the current line at the cursor and
  the cursor lands at the start of the new line.
  """
  @spec insert(t(), String.t()) :: t()
  def insert(buffer, ""), do: buffer

  def insert(buffer, text) when is_binary(text) do
    text
    |> String.split("\n")
    |> apply_inserts(buffer)
  end

  defp apply_inserts([single], buffer), do: insert_inline_chunk(buffer, single)

  defp apply_inserts([first | rest], buffer) do
    buffer
    |> insert_inline_chunk(first)
    |> insert_newline()
    |> then(&apply_inserts(rest, &1))
  end

  defp insert_inline_chunk(buffer, ""), do: buffer

  defp insert_inline_chunk(%__MODULE__{lines: lines, row: r, col: c} = b, chunk) do
    new_cells = String.graphemes(chunk)
    cells = Enum.at(lines, r)
    {before, after_} = Enum.split(cells, c)
    merged = before ++ new_cells ++ after_
    %{b | lines: List.replace_at(lines, r, merged), col: c + length(new_cells)}
  end

  @doc """
  Insert a single cell (typically an atomic non-rune inline
  object struct) at the cursor. The cell occupies exactly one
  column; cursor advances by one.
  """
  @spec insert_cell(t(), cell()) :: t()
  def insert_cell(%__MODULE__{lines: lines, row: r, col: c} = b, cell) do
    cells = Enum.at(lines, r)
    {before, after_} = Enum.split(cells, c)
    merged = before ++ [cell] ++ after_
    %{b | lines: List.replace_at(lines, r, merged), col: c + 1}
  end

  @doc """
  Insert a line break at the cursor. Splits the current line
  and moves the cursor to column 0 of the new line.
  """
  @spec insert_newline(t()) :: t()
  def insert_newline(%__MODULE__{lines: lines, row: r, col: c} = b) do
    cells = Enum.at(lines, r)
    {before, after_} = Enum.split(cells, c)

    new_lines =
      lines
      |> List.replace_at(r, before)
      |> List.insert_at(r + 1, after_)

    %{b | lines: new_lines, row: r + 1, col: 0}
  end

  @doc "Alias for `insert/2`. Kept distinct for clarity at call sites."
  @spec paste(t(), String.t()) :: t()
  def paste(buffer, text), do: insert(buffer, text)

  # ---- deletion ------------------------------------------------------------

  @doc """
  Backspace. At column 0 with a previous line, joins the
  current line into the previous one and parks the cursor at
  the join point. Otherwise removes exactly one cell — an
  inline object cell is removed atomically.
  """
  @spec delete_before(t()) :: t()
  def delete_before(%__MODULE__{row: 0, col: 0} = b), do: b

  def delete_before(%__MODULE__{lines: lines, row: r, col: 0} = b) do
    prev = Enum.at(lines, r - 1)
    cur = Enum.at(lines, r)
    new_col = length(prev)

    new_lines =
      lines
      |> List.replace_at(r - 1, prev ++ cur)
      |> List.delete_at(r)

    %{b | lines: new_lines, row: r - 1, col: new_col}
  end

  def delete_before(%__MODULE__{lines: lines, row: r, col: c} = b) do
    cells = Enum.at(lines, r)
    new_cells = List.delete_at(cells, c - 1)
    %{b | lines: List.replace_at(lines, r, new_cells), col: c - 1}
  end

  @doc """
  Forward delete. At end-of-line with a next line, joins the
  next line into the current one without moving the cursor.
  """
  @spec delete_after(t()) :: t()
  def delete_after(%__MODULE__{lines: lines, row: r, col: c} = b) do
    cells = Enum.at(lines, r)
    line_len = length(cells)

    cond do
      c < line_len ->
        %{b | lines: List.replace_at(lines, r, List.delete_at(cells, c))}

      r < length(lines) - 1 ->
        next = Enum.at(lines, r + 1)

        new_lines =
          lines
          |> List.replace_at(r, cells ++ next)
          |> List.delete_at(r + 1)

        %{b | lines: new_lines}

      true ->
        b
    end
  end

  # ---- cursor movement -----------------------------------------------------

  @spec move_left(t()) :: t()
  def move_left(%__MODULE__{row: 0, col: 0} = b), do: b

  def move_left(%__MODULE__{lines: lines, row: r, col: 0} = b) do
    %{b | row: r - 1, col: length(Enum.at(lines, r - 1))}
  end

  def move_left(%__MODULE__{col: c} = b), do: %{b | col: c - 1}

  @spec move_right(t()) :: t()
  def move_right(%__MODULE__{lines: lines, row: r, col: c} = b) do
    cells = Enum.at(lines, r)
    line_len = length(cells)

    cond do
      c < line_len -> %{b | col: c + 1}
      r < length(lines) - 1 -> %{b | row: r + 1, col: 0}
      true -> b
    end
  end

  @doc """
  Move up one row, clamping the column to the new line's width.
  At the top row, snaps the cursor to the start of the buffer.
  """
  @spec move_up(t()) :: t()
  def move_up(%__MODULE__{row: 0} = b), do: %{b | col: 0}

  def move_up(%__MODULE__{lines: lines, row: r, col: c} = b) do
    new_row = r - 1
    new_len = length(Enum.at(lines, new_row))
    %{b | row: new_row, col: min(c, new_len)}
  end

  @doc """
  Move down one row, clamping the column to the new line's width.
  At the bottom row, snaps the cursor to end of buffer.
  """
  @spec move_down(t()) :: t()
  def move_down(%__MODULE__{lines: lines, row: r, col: c} = b) do
    if r >= length(lines) - 1 do
      %{b | col: length(Enum.at(lines, r))}
    else
      new_row = r + 1
      new_len = length(Enum.at(lines, new_row))
      %{b | row: new_row, col: min(c, new_len)}
    end
  end

  @spec move_to_line_start(t()) :: t()
  def move_to_line_start(b), do: %{b | col: 0}

  @spec move_to_line_end(t()) :: t()
  def move_to_line_end(%__MODULE__{lines: lines, row: r} = b) do
    %{b | col: length(Enum.at(lines, r))}
  end

  @spec move_to_buffer_start(t()) :: t()
  def move_to_buffer_start(b), do: %{b | row: 0, col: 0}

  @spec move_to_buffer_end(t()) :: t()
  def move_to_buffer_end(%__MODULE__{lines: lines} = b) do
    last_row = length(lines) - 1
    %{b | row: last_row, col: length(Enum.at(lines, last_row))}
  end

  @doc """
  Move backward one word. At column 0, falls through to a
  plain `move_left/1` (which hops to the end of the previous
  line). Inline object cells count as non-whitespace and form
  their own one-cell word.
  """
  @spec move_word_left(t()) :: t()
  def move_word_left(%__MODULE__{row: 0, col: 0} = b), do: b
  def move_word_left(%__MODULE__{col: 0} = b), do: move_left(b)

  def move_word_left(%__MODULE__{lines: lines, row: r, col: c} = b) do
    cells = Enum.at(lines, r)
    %{b | col: previous_word_boundary(cells, c)}
  end

  @doc """
  Move forward one word. At end-of-line, falls through to a
  plain `move_right/1` (which hops to the start of the next
  line).
  """
  @spec move_word_right(t()) :: t()
  def move_word_right(%__MODULE__{lines: lines, row: r, col: c} = b) do
    cells = Enum.at(lines, r)

    if c >= length(cells) do
      move_right(b)
    else
      %{b | col: next_word_boundary(cells, c)}
    end
  end

  # ---- kill commands -------------------------------------------------------

  @doc """
  Kill from the cursor to the end of the current line. Does not
  cross line boundaries — multi-line kill is `kill_line/1`.
  """
  @spec kill_to_eol(t()) :: t()
  def kill_to_eol(%__MODULE__{lines: lines, row: r, col: c} = b) do
    cells = Enum.at(lines, r)
    new_cells = Enum.take(cells, c)
    %{b | lines: List.replace_at(lines, r, new_cells)}
  end

  @doc """
  Kill from the start of the current line to the cursor.
  """
  @spec kill_to_bol(t()) :: t()
  def kill_to_bol(%__MODULE__{lines: lines, row: r, col: c} = b) do
    cells = Enum.at(lines, r)
    new_cells = Enum.drop(cells, c)
    %{b | lines: List.replace_at(lines, r, new_cells), col: 0}
  end

  @doc """
  Kill the entire current line. If it's the only line, clears
  the buffer instead.
  """
  @spec kill_line(t()) :: t()
  def kill_line(%__MODULE__{lines: [_]}), do: new()

  def kill_line(%__MODULE__{lines: lines, row: r} = b) do
    new_lines = List.delete_at(lines, r)
    new_row = min(r, length(new_lines) - 1)
    new_len = length(Enum.at(new_lines, new_row))
    %{b | lines: new_lines, row: new_row, col: min(b.col, new_len)}
  end

  @doc """
  Kill the word immediately before the cursor. At column 0,
  falls back to `delete_before/1` so backspace-word at line
  start joins lines instead of being a no-op.
  """
  @spec kill_word(t()) :: t()
  def kill_word(%__MODULE__{col: 0} = b), do: delete_before(b)

  def kill_word(%__MODULE__{lines: lines, row: r, col: c} = b) do
    cells = Enum.at(lines, r)
    new_col = previous_word_boundary(cells, c)
    new_cells = Enum.take(cells, new_col) ++ Enum.drop(cells, c)
    %{b | lines: List.replace_at(lines, r, new_cells), col: new_col}
  end

  @doc """
  Kill the word immediately after the cursor.
  """
  @spec kill_word_forward(t()) :: t()
  def kill_word_forward(%__MODULE__{lines: lines, row: r, col: c} = b) do
    cells = Enum.at(lines, r)
    word_end = next_word_boundary(cells, c)
    new_cells = Enum.take(cells, c) ++ Enum.drop(cells, word_end)
    %{b | lines: List.replace_at(lines, r, new_cells)}
  end

  # ---- internal helpers ----------------------------------------------------

  # Word boundary semantics: a cell is "whitespace" iff it is
  # one of the grapheme strings " ", "\t", "\n". Any non-binary
  # cell counts as non-whitespace, so it forms its own one-cell
  # "word" that kill_word and move_word_* will skip in a single
  # hop.
  defp whitespace_cell?(" "), do: true
  defp whitespace_cell?("\t"), do: true
  defp whitespace_cell?("\n"), do: true
  defp whitespace_cell?(_), do: false

  defp previous_word_boundary(cells, idx) do
    skip_ws = drop_while_reverse(cells, idx, &whitespace_cell?/1)
    drop_while_reverse(cells, skip_ws, &(not whitespace_cell?(&1)))
  end

  defp next_word_boundary(cells, idx) do
    len = length(cells)
    skip_ws = advance_while(cells, idx, len, &whitespace_cell?/1)
    advance_while(cells, skip_ws, len, &(not whitespace_cell?(&1)))
  end

  defp advance_while(_cells, idx, len, _pred) when idx >= len, do: len

  defp advance_while(cells, idx, len, pred) do
    if pred.(Enum.at(cells, idx)),
      do: advance_while(cells, idx + 1, len, pred),
      else: idx
  end

  defp drop_while_reverse(_cells, 0, _pred), do: 0

  defp drop_while_reverse(cells, idx, pred) do
    if pred.(Enum.at(cells, idx - 1)),
      do: drop_while_reverse(cells, idx - 1, pred),
      else: idx
  end
end
