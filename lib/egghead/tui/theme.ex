defmodule Egghead.TUI.Theme do
  @moduledoc """
  Styles for the Egghead TUI. Uses TermUI.Renderer.Style with {r,g,b} tuples.

  Currently the active theme is "System" — most styles use nil bg
  (→ Cell :default → terminal's native background) so the TUI inherits
  the user's terminal theme. Only chrome bars and selection set explicit
  bg. See `records/design/tui-theme-system.md` for the full theme system
  design (Mocha, Latte palettes that own every cell).
  """

  alias TermUI.Renderer.Style

  @doc """
  System theme constructor — formalizes the current default colors.
  Future: switch the helper functions below to read from the active theme.
  """
  def system do
    %{
      name: "System",
      bg: nil,
      fg: nil,
      fg_muted: :bright_black,
      fg_accent: :cyan,
      chrome_bg: :bright_black,
      chrome_fg: :white,
      sel_bg: :cyan,
      sel_fg: :black
    }
  end

  # --- Styles ---

  # Chrome — header and status bar have dark bg to stand out
  def header_bar, do: Style.new(fg: :cyan, bg: :bright_black, attrs: [:bold])
  def prompt, do: Style.new(fg: :cyan)
  def normal, do: Style.new(fg: :white)
  def muted, do: Style.new(fg: :bright_black)
  def selected, do: Style.new(fg: :black, bg: :cyan, attrs: [:bold])
  def separator, do: Style.new(fg: :bright_black)
  def status_bar_line, do: Style.new(fg: :white, bg: :bright_black)
  def link, do: Style.new(fg: :cyan, attrs: [:underline])
  def accent, do: Style.new(fg: :cyan)
  # The local human's voice in chat — bright, bold so it stands out
  # against agent messages.
  def user, do: Style.new(fg: :bright_cyan, attrs: [:bold])

  # Stable per-agent color from a fixed palette of safe terminal colors.
  # Hashes the agent id (or nick) so the same agent always gets the same
  # color across runs and machines.
  @agent_palette [:cyan, :green, :yellow, :magenta, :blue, :red]

  def agent_color(id) when is_binary(id) do
    i = :erlang.phash2(id, length(@agent_palette))
    Style.new(fg: Enum.at(@agent_palette, i), attrs: [:bold])
  end

  def agent_color(_), do: Style.new(fg: :white, attrs: [:bold])

  # Markdown styles
  def md_h1, do: Style.new(fg: :cyan, attrs: [:bold])
  def md_h2, do: Style.new(fg: :cyan, attrs: [:bold])
  def md_h3, do: Style.new(fg: :white, attrs: [:bold])
  def md_bold, do: Style.new(attrs: [:bold])
  def md_italic, do: Style.new(attrs: [:italic])
  def md_code, do: Style.new(fg: :yellow)
  def md_code_block, do: Style.new(fg: :bright_black)
  def md_list_bullet, do: Style.new(fg: :cyan)
end
