defmodule Egghead.TUI.Theme do
  @moduledoc """
  Styles for the Egghead TUI. Uses TermUI.Renderer.Style with {r,g,b} tuples.
  """

  alias TermUI.Renderer.Style

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
