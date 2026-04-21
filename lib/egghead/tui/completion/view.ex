defmodule Egghead.TUI.Completion.View do
  @moduledoc """
  Shared dropdown renderer for `Egghead.TUI.Completion`.

  Sized and styled to sit directly above the input row — same
  visual shape `SelectList` uses for its modal pickers, but the
  interaction model stays completion-style (no header band,
  no title line — the dropdown blends into the input area).
  """

  import Egghead.OpenTUI.View

  alias Egghead.OpenTUI.Colors
  alias Egghead.TUI.Completion

  @max_rows 6

  @doc "Number of rows the dropdown occupies, 0 when closed."
  @spec height(Completion.t() | nil) :: non_neg_integer()
  def height(nil), do: 0
  def height(%Completion{candidates: cs}), do: min(length(cs), @max_rows)

  @doc "Render the dropdown as a width-wide vbox of styled rows."
  @spec render(Completion.t(), pos_integer(), pos_integer()) :: Egghead.OpenTUI.View.tree()
  def render(%Completion{} = completion, width, height) do
    rows =
      completion.candidates
      |> Enum.take(height)
      |> Enum.with_index()
      |> Enum.map(fn {candidate, idx} ->
        row(completion.provider, candidate, idx == completion.selected, width)
      end)

    vbox([height: height], rows)
  end

  # ---- Internals ----------------------------------------------------------

  defp row(provider, candidate, selected?, width) do
    label = provider.label(candidate)
    hint = hint_for(provider, candidate)

    inner =
      case hint do
        nil -> "  #{label}"
        text -> "  #{label}  #{text}"
      end

    padded = pad_to(inner, width) |> String.slice(0, width)

    text(padded,
      height: 1,
      fg: if(selected?, do: Colors.fg(), else: Colors.accent()),
      bg: if(selected?, do: Colors.selection_bg(), else: Colors.bg())
    )
  end

  defp hint_for(provider, candidate) do
    if function_exported?(provider, :hint, 1),
      do: provider.hint(candidate),
      else: nil
  end

  defp pad_to(str, width) do
    len = String.length(str)

    if len >= width,
      do: str,
      else: str <> String.duplicate(" ", width - len)
  end
end
