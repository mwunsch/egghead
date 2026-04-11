defmodule Egghead.OpenTUI.Style do
  @moduledoc """
  Lightweight style record for view-tree leaves.

  A `Style` carries an fg color binary, an optional bg color
  binary (use `:transparent` for "no background fill"), and an
  attribute bitfield (bold, underline, reverse, etc. — reserved
  for future use; always 0 today).

  Color binaries are 16-byte little-endian f32 RGBA values, the
  same format `Egghead.OpenTUI.Bridge.draw_text/7` and
  `Bridge.fill_rect/6` expect. See `Egghead.OpenTUI.Colors`.

  This module is the *only* abstraction view code uses to
  describe styling — the bridge's binary-color shape stays
  internal to `Renderer`.
  """

  alias Egghead.OpenTUI.Colors

  @type t :: %__MODULE__{
          fg: binary(),
          bg: binary() | :transparent,
          attrs: non_neg_integer()
        }

  defstruct fg: nil, bg: :transparent, attrs: 0

  @doc "Build a style from keyword opts. Defaults: white fg, transparent bg, no attrs."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      fg: Keyword.get(opts, :fg, Colors.white()),
      bg: Keyword.get(opts, :bg, :transparent),
      attrs: Keyword.get(opts, :attrs, 0)
    }
  end

  @doc "Default style: white on transparent."
  def default, do: new()

  @doc """
  Resolve a `:bg` value to a binary the bridge can consume.
  `:transparent` becomes the empty binary, which `draw_text`
  treats as 'no background fill'.
  """
  @spec bg_binary(binary() | :transparent) :: binary()
  def bg_binary(:transparent), do: Colors.transparent()
  def bg_binary(bin) when is_binary(bin), do: bin
end
