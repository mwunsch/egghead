defmodule Egghead.OpenTUI.Attrs do
  @moduledoc """
  Text attribute bitfield constants matching OpenTUI's
  `TextAttributes` (see `packages/core/src/zig/ansi.zig`
  upstream). Pass any OR-ed combination as the `:attrs` opt on
  a `Egghead.OpenTUI.View.text/2` leaf and the renderer forwards
  it to `Bridge.draw_text/7` as the `attributes: u32` argument.

  Bit layout:

      BOLD          1 << 0   = 1
      DIM           1 << 1   = 2
      ITALIC        1 << 2   = 4
      UNDERLINE     1 << 3   = 8
      BLINK         1 << 4   = 16
      STRIKETHROUGH 1 << 7   = 128

  These match OpenTUI's `TextAttributes` constants exactly. The
  gap between BLINK (bit 4) and STRIKETHROUGH (bit 7) is
  intentional upstream — bits 5–6 are reserved for inverse and
  hidden, which we don't expose yet.
  """

  @bold 1
  @dim 2
  @italic 4
  @underline 8
  @blink 16
  @strikethrough 128

  @doc "Bold (SGR 1)."
  def bold, do: @bold

  @doc "Dim / faint (SGR 2)."
  def dim, do: @dim

  @doc "Italic (SGR 3)."
  def italic, do: @italic

  @doc "Underline (SGR 4)."
  def underline, do: @underline

  @doc "Blink (SGR 5). Use sparingly."
  def blink, do: @blink

  @doc "Strikethrough (SGR 9)."
  def strikethrough, do: @strikethrough

  @doc "OR several attributes together: `combine([:bold, :italic])`."
  @spec combine([atom()]) :: non_neg_integer()
  def combine(list) when is_list(list) do
    Enum.reduce(list, 0, fn name, acc ->
      Bitwise.bor(acc, lookup(name))
    end)
  end

  defp lookup(:bold), do: @bold
  defp lookup(:dim), do: @dim
  defp lookup(:italic), do: @italic
  defp lookup(:underline), do: @underline
  defp lookup(:blink), do: @blink
  defp lookup(:strikethrough), do: @strikethrough
end
