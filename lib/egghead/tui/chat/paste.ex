defmodule Egghead.TUI.Chat.Paste do
  @moduledoc """
  A pasted blob held as a single atomic cell in the chat input
  buffer.

  When the user pastes a long block (`>3` lines OR `>150` chars),
  `Egghead.TUI.Chat.Update` wraps it in a `%Paste{}` struct and
  inserts it as a single cell into the `Egghead.OpenTUI.EditBuffer`.
  Cursor and delete operations treat the cell atomically — one
  Backspace removes the whole chip — and the rendered chip shows
  a 📋 glyph plus a one-line preview of the original content
  ("first ~25 chars or first 2 tokens, +N lines"), with a tinted
  background, instead of the raw payload.

  At submit time `EditBuffer.to_text/1` substitutes each paste
  cell back to its `:full_text`, so `Egghead.chat/2` always
  receives the original verbatim content. The chip is purely a
  display affordance.

  ## Threshold

  Below `>3` lines AND `>150` chars, paste is inserted as plain
  text via `EditBuffer.paste/2`. Above either threshold, it
  becomes a chip via `EditBuffer.insert_paste/2`.

  ## Why head + line count

  When you scroll back through a chat transcript, "Pasted #3"
  tells you nothing. `📋 def fizz(n): +12 lines` is instantly
  recognisable as "the function I pasted earlier". The head is
  the first non-empty line, clipped to ~25 chars (whole word
  cut where possible) and ellipsised; the line count is omitted
  when the paste is a single line.
  """

  @type t :: %__MODULE__{
          id: pos_integer(),
          head: String.t(),
          line_count: non_neg_integer(),
          full_text: String.t()
        }

  defstruct id: 0, head: "", line_count: 0, full_text: ""

  @max_head_chars 25
  @threshold_lines 3
  @threshold_chars 150

  @doc """
  True when `text` is large enough to be wrapped in a chip rather
  than inserted inline.
  """
  @spec chip_worthy?(String.t()) :: boolean()
  def chip_worthy?(text) when is_binary(text) do
    line_count = count_extra_lines(text)
    line_count > @threshold_lines or String.length(text) > @threshold_chars
  end

  @doc """
  Build a `%Paste{}` from a raw payload. Caller assigns the
  monotonic `:id` (typically `model.next_paste_id`).
  """
  @spec build(pos_integer(), String.t()) :: t()
  def build(id, text) when is_integer(id) and is_binary(text) do
    %__MODULE__{
      id: id,
      head: head_preview(text),
      line_count: count_extra_lines(text),
      full_text: text
    }
  end

  @doc """
  Display string for the chip body, without the chrome glyph or
  background colour. Always ends in `…` so the head reads as "a
  segment from a longer paste" rather than the whole content.
  Used by the renderer and by tests.
  """
  @spec display(t()) :: String.t()
  def display(%__MODULE__{head: head, line_count: 0}), do: "#{head}…"

  def display(%__MODULE__{head: head, line_count: n}), do: "#{head}… +#{n} lines"

  @doc """
  Head segment rendered as `📋 head…` — the always-visible part
  of the chip. Renderers paint this with the chip's accent fg
  and tinted bg.
  """
  @spec head_segment(t()) :: String.t()
  def head_segment(%__MODULE__{head: head}), do: "📋 #{head}…"

  @doc """
  Tail segment ` +N lines`, or `nil` for a single-line paste.
  Renderers paint this italicised + dim, on the same chip bg.
  """
  @spec tail_segment(t()) :: String.t() | nil
  def tail_segment(%__MODULE__{line_count: 0}), do: nil
  def tail_segment(%__MODULE__{line_count: n}), do: " +#{n} lines"

  # Number of newlines after the first line. A single-line paste
  # of 200 chars returns 0 here; a 5-line paste returns 4.
  defp count_extra_lines(text) do
    text
    |> String.split("\n")
    |> length()
    |> Kernel.-(1)
  end

  # First non-empty line, clipped to ~25 chars on a word boundary
  # where possible. Always single-line, never trailing whitespace.
  defp head_preview(text) do
    first_line =
      text
      |> String.split("\n")
      |> Enum.find("", fn line -> String.trim(line) != "" end)
      |> String.trim()

    cond do
      first_line == "" ->
        "(empty)"

      String.length(first_line) <= @max_head_chars ->
        first_line

      true ->
        clip_with_ellipsis(first_line, @max_head_chars)
    end
  end

  # Clip to `n` graphemes; prefer cutting at the last whitespace
  # within the budget so we don't slice mid-word. Append `…` to
  # mark truncation.
  defp clip_with_ellipsis(text, n) do
    head = String.slice(text, 0, n)

    case :binary.match(head, " ") do
      :nomatch ->
        head <> "…"

      _ ->
        case String.split(head, " ") |> Enum.reverse() do
          [_partial | rest] when rest != [] ->
            (rest |> Enum.reverse() |> Enum.join(" ")) <> "…"

          _ ->
            head <> "…"
        end
    end
  end
end
