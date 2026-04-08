defmodule Egghead.OpenTUI.Colors do
  @moduledoc """
  Default palette as compile-time color binaries.

  OpenTUI's C ABI takes colors as four little-endian f32s
  (r, g, b, a), so the bridge NIF accepts a 16-byte binary in
  that exact layout. This module precomputes a small palette
  at compile time so render loops never allocate color values.

  Pass `transparent/0` (the empty binary) where the bridge
  expects a bg argument that should mean "no background fill."

  Applications that need a richer palette can either build their
  own binaries with `rgba/4` or define a domain-specific module
  alongside this one.
  """

  @doc "Pack four 0.0–1.0 floats into a 16-byte little-endian color binary."
  @spec rgba(float(), float(), float(), float()) :: binary()
  def rgba(r, g, b, a) do
    <<r::float-32-little, g::float-32-little, b::float-32-little, a::float-32-little>>
  end

  @doc "Empty binary — sentinel for 'no background' in `Bridge.draw_text/7`."
  @spec transparent() :: binary()
  def transparent, do: <<>>

  # ---- Default palette ----------------------------------------------------
  #
  # Distinct, saturated, easy to tell apart visually and in spans snapshots.
  # Compile-time literals so the render loop reuses the same binary refs.

  @bg <<0.06::float-32-little, 0.06::float-32-little, 0.08::float-32-little,
        1.0::float-32-little>>
  @red <<0.95::float-32-little, 0.30::float-32-little, 0.30::float-32-little,
         1.0::float-32-little>>
  @green <<0.36::float-32-little, 0.85::float-32-little, 0.40::float-32-little,
           1.0::float-32-little>>
  @blue <<0.40::float-32-little, 0.55::float-32-little, 0.95::float-32-little,
          1.0::float-32-little>>
  @cyan <<0.36::float-32-little, 0.80::float-32-little, 0.85::float-32-little,
          1.0::float-32-little>>
  @magenta <<0.85::float-32-little, 0.40::float-32-little, 0.85::float-32-little,
             1.0::float-32-little>>
  @yellow <<0.92::float-32-little, 0.85::float-32-little, 0.30::float-32-little,
            1.0::float-32-little>>
  @white <<0.92::float-32-little, 0.92::float-32-little, 0.92::float-32-little,
           1.0::float-32-little>>
  @dim <<0.55::float-32-little, 0.55::float-32-little, 0.60::float-32-little,
         1.0::float-32-little>>
  @accent <<0.36::float-32-little, 0.80::float-32-little, 0.85::float-32-little,
            1.0::float-32-little>>
  @heading <<0.95::float-32-little, 0.90::float-32-little, 0.50::float-32-little,
             1.0::float-32-little>>
  @code <<0.75::float-32-little, 0.85::float-32-little, 0.95::float-32-little,
          1.0::float-32-little>>
  @link <<0.55::float-32-little, 0.78::float-32-little, 0.95::float-32-little,
          1.0::float-32-little>>
  @muted <<0.45::float-32-little, 0.45::float-32-little, 0.50::float-32-little,
           1.0::float-32-little>>
  @selected_bg <<0.20::float-32-little, 0.30::float-32-little, 0.45::float-32-little,
                 1.0::float-32-little>>

  def bg, do: @bg
  def red, do: @red
  def green, do: @green
  def blue, do: @blue
  def cyan, do: @cyan
  def magenta, do: @magenta
  def yellow, do: @yellow
  def white, do: @white
  def dim, do: @dim
  def accent, do: @accent
  def heading, do: @heading
  def code, do: @code
  def link, do: @link
  def muted, do: @muted
  def selected_bg, do: @selected_bg
end
