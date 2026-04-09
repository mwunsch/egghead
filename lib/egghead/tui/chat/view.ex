defmodule Egghead.TUI.Chat.View do
  @moduledoc """
  Pure view function for the chat screen. Phase 6a renders a
  static placeholder centred between a header and status bar so
  the routing wiring can be exercised end-to-end. Real layout
  (transcript pane, sidebar, input box) lands in Phase 6c.
  """

  import Egghead.OpenTUI.View
  alias Egghead.OpenTUI.Colors
  alias Egghead.TUI.Chat.Model

  @spec render(Model.t()) :: Egghead.OpenTUI.View.tree()
  def render(%Model{} = model) do
    width = model.width

    vbox([
      header(width),
      fill(flex: 1),
      placeholder_line("chat mode — Phase 6a placeholder"),
      placeholder_line("press Esc to return to records mode"),
      fill(flex: 1),
      status_bar(width)
    ])
  end

  defp header(width) do
    label = " egghead · chat "
    pad = max(width - String.length(label), 0)
    line = label <> String.duplicate(" ", pad)

    text(line,
      height: 1,
      fg: Colors.white(),
      bg: Colors.selected_bg()
    )
  end

  defp placeholder_line(content) do
    hbox(
      [height: 1],
      [
        fill(flex: 1),
        text(content, fg: Colors.muted()),
        fill(flex: 1)
      ]
    )
  end

  defp status_bar(width) do
    label = " CHAT │ esc records │ ^q quit"
    pad = max(width - String.length(label), 0)
    line = label <> String.duplicate(" ", pad)

    text(line,
      height: 1,
      fg: Colors.white(),
      bg: Colors.selected_bg()
    )
  end
end
