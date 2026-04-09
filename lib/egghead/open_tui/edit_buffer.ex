defmodule Egghead.OpenTUI.EditBuffer do
  @moduledoc """
  Pure functional multi-line text buffer.

  Where `Egghead.OpenTUI.Readline` operates on a single
  `(text, cursor)` pair, `EditBuffer` carries a list of lines
  plus a `(row, col)` cursor and adds row navigation, line
  splits/joins, and line-aware kill commands. Within a line we
  delegate to `Readline` so single-line behaviour stays
  consistent everywhere a buffer is edited.

  All operations are grapheme-aware via `String.graphemes/1`.
  Pure: no I/O, no view; same testing pattern as `Readline`.
  """

  alias Egghead.OpenTUI.Readline

  defstruct lines: [""], row: 0, col: 0

  @type t :: %__MODULE__{
          lines: [String.t()],
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
    lines = String.split(text, "\n")
    last = List.last(lines)
    %__MODULE__{lines: lines, row: length(lines) - 1, col: String.length(last)}
  end

  @spec to_text(t()) :: String.t()
  def to_text(%__MODULE__{lines: lines}), do: Enum.join(lines, "\n")

  @spec clear(t()) :: t()
  def clear(_), do: new()

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{lines: [""]}), do: true
  def empty?(_), do: false

  @spec cursor(t()) :: {non_neg_integer(), non_neg_integer()}
  def cursor(%__MODULE__{row: r, col: c}), do: {r, c}

  @spec line_count(t()) :: pos_integer()
  def line_count(%__MODULE__{lines: lines}), do: length(lines)

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

  defp apply_inserts([single], buffer), do: insert_inline(buffer, single)

  defp apply_inserts([first | rest], buffer) do
    buffer
    |> insert_inline(first)
    |> insert_newline()
    |> then(&apply_inserts(rest, &1))
  end

  defp insert_inline(buffer, ""), do: buffer

  defp insert_inline(%__MODULE__{lines: lines, row: r, col: c} = b, chunk) do
    line = Enum.at(lines, r)
    {new_line, new_col} = Readline.insert(line, c, chunk)
    %{b | lines: List.replace_at(lines, r, new_line), col: new_col}
  end

  @doc """
  Insert a line break at the cursor. Splits the current line
  and moves the cursor to column 0 of the new line.
  """
  @spec insert_newline(t()) :: t()
  def insert_newline(%__MODULE__{lines: lines, row: r, col: c} = b) do
    line = Enum.at(lines, r)
    {before, rest} = split_at_grapheme(line, c)

    new_lines =
      lines
      |> List.replace_at(r, before)
      |> List.insert_at(r + 1, rest)

    %{b | lines: new_lines, row: r + 1, col: 0}
  end

  @doc "Alias for `insert/2`. Kept distinct for clarity at call sites."
  @spec paste(t(), String.t()) :: t()
  def paste(buffer, text), do: insert(buffer, text)

  # ---- deletion ------------------------------------------------------------

  @doc """
  Backspace. At column 0 with a previous line, joins the
  current line into the previous one and parks the cursor at
  the join point.
  """
  @spec delete_before(t()) :: t()
  def delete_before(%__MODULE__{row: 0, col: 0} = b), do: b

  def delete_before(%__MODULE__{lines: lines, row: r, col: 0} = b) do
    prev = Enum.at(lines, r - 1)
    cur = Enum.at(lines, r)
    new_col = String.length(prev)

    new_lines =
      lines
      |> List.replace_at(r - 1, prev <> cur)
      |> List.delete_at(r)

    %{b | lines: new_lines, row: r - 1, col: new_col}
  end

  def delete_before(%__MODULE__{lines: lines, row: r, col: c} = b) do
    line = Enum.at(lines, r)
    {new_line, new_col} = Readline.delete_before(line, c)
    %{b | lines: List.replace_at(lines, r, new_line), col: new_col}
  end

  @doc """
  Forward delete. At end-of-line with a next line, joins the
  next line into the current one without moving the cursor.
  """
  @spec delete_after(t()) :: t()
  def delete_after(%__MODULE__{lines: lines, row: r, col: c} = b) do
    line = Enum.at(lines, r)
    line_len = String.length(line)

    cond do
      c < line_len ->
        graphemes = String.graphemes(line)
        new_line = (Enum.take(graphemes, c) ++ Enum.drop(graphemes, c + 1)) |> Enum.join()
        %{b | lines: List.replace_at(lines, r, new_line)}

      r < length(lines) - 1 ->
        next = Enum.at(lines, r + 1)

        new_lines =
          lines
          |> List.replace_at(r, line <> next)
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
    %{b | row: r - 1, col: String.length(Enum.at(lines, r - 1))}
  end

  def move_left(%__MODULE__{col: c} = b), do: %{b | col: c - 1}

  @spec move_right(t()) :: t()
  def move_right(%__MODULE__{lines: lines, row: r, col: c} = b) do
    line = Enum.at(lines, r)
    line_len = String.length(line)

    cond do
      c < line_len -> %{b | col: c + 1}
      r < length(lines) - 1 -> %{b | row: r + 1, col: 0}
      true -> b
    end
  end

  @doc """
  Move up one row, clamping the column to the new line's length.
  At the top row, snaps the cursor to the start of the buffer.
  """
  @spec move_up(t()) :: t()
  def move_up(%__MODULE__{row: 0} = b), do: %{b | col: 0}

  def move_up(%__MODULE__{lines: lines, row: r, col: c} = b) do
    new_row = r - 1
    new_len = String.length(Enum.at(lines, new_row))
    %{b | row: new_row, col: min(c, new_len)}
  end

  @doc """
  Move down one row, clamping the column to the new line's length.
  At the bottom row, snaps the cursor to end of buffer.
  """
  @spec move_down(t()) :: t()
  def move_down(%__MODULE__{lines: lines, row: r, col: c} = b) do
    if r >= length(lines) - 1 do
      %{b | col: String.length(Enum.at(lines, r))}
    else
      new_row = r + 1
      new_len = String.length(Enum.at(lines, new_row))
      %{b | row: new_row, col: min(c, new_len)}
    end
  end

  @spec move_to_line_start(t()) :: t()
  def move_to_line_start(b), do: %{b | col: 0}

  @spec move_to_line_end(t()) :: t()
  def move_to_line_end(%__MODULE__{lines: lines, row: r} = b) do
    %{b | col: String.length(Enum.at(lines, r))}
  end

  @spec move_to_buffer_start(t()) :: t()
  def move_to_buffer_start(b), do: %{b | row: 0, col: 0}

  @spec move_to_buffer_end(t()) :: t()
  def move_to_buffer_end(%__MODULE__{lines: lines} = b) do
    last_row = length(lines) - 1
    %{b | row: last_row, col: String.length(Enum.at(lines, last_row))}
  end

  @doc """
  Move backward one word. At column 0, falls through to a
  plain `move_left/1` (which hops to the end of the previous
  line). Within a line, delegates to `Readline.move_word_left/2`.
  """
  @spec move_word_left(t()) :: t()
  def move_word_left(%__MODULE__{row: 0, col: 0} = b), do: b
  def move_word_left(%__MODULE__{col: 0} = b), do: move_left(b)

  def move_word_left(%__MODULE__{lines: lines, row: r, col: c} = b) do
    line = Enum.at(lines, r)
    {_, new_col} = Readline.move_word_left(line, c)
    %{b | col: new_col}
  end

  @doc """
  Move forward one word. At end-of-line, falls through to a
  plain `move_right/1` (which hops to the start of the next
  line). Within a line, delegates to `Readline.move_word_right/2`.
  """
  @spec move_word_right(t()) :: t()
  def move_word_right(%__MODULE__{lines: lines, row: r, col: c} = b) do
    line = Enum.at(lines, r)

    if c >= String.length(line) do
      move_right(b)
    else
      {_, new_col} = Readline.move_word_right(line, c)
      %{b | col: new_col}
    end
  end

  # ---- kill commands -------------------------------------------------------

  @doc """
  Kill from the cursor to the end of the current line. Does not
  cross line boundaries — multi-line kill is `kill_line/1`.
  """
  @spec kill_to_eol(t()) :: t()
  def kill_to_eol(%__MODULE__{lines: lines, row: r, col: c} = b) do
    line = Enum.at(lines, r)
    {new_line, _} = Readline.kill_to_eol(line, c)
    %{b | lines: List.replace_at(lines, r, new_line)}
  end

  @doc """
  Kill from the start of the current line to the cursor.
  """
  @spec kill_to_bol(t()) :: t()
  def kill_to_bol(%__MODULE__{lines: lines, row: r, col: c} = b) do
    line = Enum.at(lines, r)
    {new_line, new_col} = Readline.kill_to_bol(line, c)
    %{b | lines: List.replace_at(lines, r, new_line), col: new_col}
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
    new_len = String.length(Enum.at(new_lines, new_row))
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
    line = Enum.at(lines, r)
    {new_line, new_col} = Readline.kill_word(line, c)
    %{b | lines: List.replace_at(lines, r, new_line), col: new_col}
  end

  @doc """
  Kill the word immediately after the cursor.
  """
  @spec kill_word_forward(t()) :: t()
  def kill_word_forward(%__MODULE__{lines: lines, row: r, col: c} = b) do
    line = Enum.at(lines, r)
    {new_line, _} = Readline.kill_word_forward(line, c)
    %{b | lines: List.replace_at(lines, r, new_line)}
  end

  # ---- internal helpers ----------------------------------------------------

  defp split_at_grapheme(s, n) do
    graphemes = String.graphemes(s)
    {Enum.take(graphemes, n) |> Enum.join(), Enum.drop(graphemes, n) |> Enum.join()}
  end
end
