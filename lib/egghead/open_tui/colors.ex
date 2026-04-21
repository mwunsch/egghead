defmodule Egghead.OpenTUI.Colors do
  @moduledoc """
  Palette accessors backed by the active theme (`Egghead.OpenTUI.Theme`).

  Every accessor returns a 16-byte little-endian RGBA binary that
  `Bridge.draw_text/7` and `Bridge.fill_rect/6` accept directly.
  The `bg/0` and `bg_alt/0` slots may return the empty binary —
  the bridge reads that as "no background fill," letting the host
  terminal's own background bleed through.

  Colors resolve through `:persistent_term` at call time, so
  `Egghead.OpenTUI.Theme.set/1` takes effect on the next frame
  with no view-tree plumbing.

  ## Semantic slots

  The theme defines 17 slots:

      bg              bg_alt          fg              fg_dim       fg_muted
      selection_bg    accent          border          error        warning
      success         info            syntax_heading  syntax_link  syntax_code
      syntax_keyword  syntax_string

  Prefer these over the legacy aliases below when authoring new code.

  ## Legacy aliases

  A handful of older names (`white`, `red`, `green`, `cyan`,
  `magenta`, `blue`, `yellow`, `dim`, `muted`, `heading`, `code`,
  `link`, `selected_bg`) still exist and map onto the semantic
  slots that best fit their historical use. They remain so the
  refactor doesn't churn 168 call sites in one go — new code
  should use the semantic names directly.
  """

  alias Egghead.OpenTUI.Theme

  @doc "Pack four 0.0–1.0 floats into a 16-byte little-endian color binary."
  @spec rgba(float(), float(), float(), float()) :: binary()
  def rgba(r, g, b, a) do
    <<r::float-32-little, g::float-32-little, b::float-32-little, a::float-32-little>>
  end

  @doc "Empty binary — sentinel for 'no background' in `Bridge.draw_text/7`."
  @spec transparent() :: binary()
  def transparent, do: <<>>

  # ---- Semantic slots -----------------------------------------------------

  def bg, do: Theme.get(:bg)
  def bg_alt, do: Theme.get(:bg_alt)
  def fg, do: Theme.get(:fg)
  def fg_dim, do: Theme.get(:fg_dim)
  def fg_muted, do: Theme.get(:fg_muted)
  def selection_bg, do: Theme.get(:selection_bg)
  def accent, do: Theme.get(:accent)
  def border, do: Theme.get(:border)
  def error, do: Theme.get(:error)
  def warning, do: Theme.get(:warning)
  def success, do: Theme.get(:success)
  def info, do: Theme.get(:info)
  def syntax_heading, do: Theme.get(:syntax_heading)
  def syntax_link, do: Theme.get(:syntax_link)
  def syntax_code, do: Theme.get(:syntax_code)
  def syntax_keyword, do: Theme.get(:syntax_keyword)
  def syntax_string, do: Theme.get(:syntax_string)

  # ---- Legacy aliases -----------------------------------------------------
  #
  # Older code uses hue-named accessors (white/red/green/…) and
  # role-named ones (heading/code/link/muted/dim/selected_bg).
  # Map each onto the closest semantic slot so existing views
  # keep working while theme switching takes effect everywhere.

  def white, do: Theme.get(:fg)
  def dim, do: Theme.get(:fg_dim)
  def muted, do: Theme.get(:fg_muted)
  def red, do: Theme.get(:error)
  def yellow, do: Theme.get(:warning)
  def green, do: Theme.get(:success)
  def cyan, do: Theme.get(:info)
  def blue, do: Theme.get(:accent)
  def magenta, do: Theme.get(:syntax_keyword)
  def heading, do: Theme.get(:syntax_heading)
  def code, do: Theme.get(:syntax_code)
  def link, do: Theme.get(:syntax_link)
  def selected_bg, do: Theme.get(:selection_bg)
end
