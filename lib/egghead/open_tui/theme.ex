defmodule Egghead.OpenTUI.Theme do
  @moduledoc """
  Active theme for the OpenTUI framework.

  A theme is a palette — a map from one of the 17 semantic slots
  below to a 16-byte RGBA color binary (see `Egghead.OpenTUI.Colors`).
  The active palette lives in `:persistent_term` so `Colors.*`
  lookups are O(1) and shared across every render.

  ## Slots

      bg              bg_alt          fg              fg_dim       fg_muted
      selection_bg    accent          border          error        warning
      success         info            syntax_heading  syntax_link  syntax_code
      syntax_keyword  syntax_string

  The `bg` and `bg_alt` slots may be `:transparent` (the empty
  binary), which the bridge treats as "no fill" — the terminal's
  own background bleeds through. Other slots must be full RGBA
  binaries.

  ## Switching themes

      Egghead.OpenTUI.Theme.set(%{
        bg: Colors.rgba(0.1, 0.1, 0.12, 1.0),
        fg: Colors.rgba(0.92, 0.92, 0.92, 1.0),
        ...
      })

  Any call to `Egghead.OpenTUI.Colors.accent/0`, `fg/0`, etc. after
  `set/1` returns sees the new palette. Missing slots in the map
  passed to `set/1` are filled with the fallback defaults so
  partial palettes are always safe.

  ## Framework purity

  This module lives in the framework layer and does not reference
  any `Egghead.*` application module. Apps that want a catalogue
  of named themes and user-authored overrides build on top of it
  (see `Egghead.Theme`).
  """

  @slots [
    :bg,
    :bg_alt,
    :fg,
    :fg_dim,
    :fg_muted,
    :selection_bg,
    :accent,
    :border,
    :error,
    :warning,
    :success,
    :info,
    :syntax_heading,
    :syntax_link,
    :syntax_code,
    :syntax_keyword,
    :syntax_string
  ]

  @slot_count length(@slots)
  @slot_index @slots |> Enum.with_index() |> Map.new()

  @pt_key {__MODULE__, :active}

  @type slot ::
          :bg
          | :bg_alt
          | :fg
          | :fg_dim
          | :fg_muted
          | :selection_bg
          | :accent
          | :border
          | :error
          | :warning
          | :success
          | :info
          | :syntax_heading
          | :syntax_link
          | :syntax_code
          | :syntax_keyword
          | :syntax_string

  @type color :: binary() | :transparent
  @type palette :: %{optional(slot()) => color()}

  @doc "All semantic slot names in fixed order."
  @spec slots() :: [slot()]
  def slots, do: @slots

  @doc "Fast slot read. Returns the 16-byte RGBA binary or the empty binary for transparent."
  @spec get(slot()) :: binary()
  def get(slot) do
    idx = Map.fetch!(@slot_index, slot)
    ensure_loaded() |> elem(idx)
  end

  @doc """
  Install `palette` as the active theme. Missing slots fall back
  to the framework's built-in neutral defaults.
  """
  @spec set(palette()) :: :ok
  def set(palette) when is_map(palette) do
    defaults = fallback_tuple()
    tuple = build_tuple(palette, defaults)
    :persistent_term.put(@pt_key, tuple)
    :ok
  end

  @doc "Return the active palette as a map — handy for debugging."
  @spec active() :: %{slot() => binary()}
  def active do
    tuple = ensure_loaded()
    @slots |> Enum.with_index() |> Map.new(fn {slot, idx} -> {slot, elem(tuple, idx)} end)
  end

  @doc false
  def __slot_index__(slot), do: Map.fetch!(@slot_index, slot)

  @doc false
  def __slot_count__, do: @slot_count

  # -------------------------------------------------------------------
  # Internals
  # -------------------------------------------------------------------

  defp ensure_loaded do
    case :persistent_term.get(@pt_key, :undefined) do
      :undefined ->
        tuple = fallback_tuple()
        :persistent_term.put(@pt_key, tuple)
        tuple

      tuple ->
        tuple
    end
  end

  defp build_tuple(palette, defaults) do
    @slots
    |> Enum.with_index()
    |> Enum.map(fn {slot, idx} ->
      case Map.get(palette, slot) do
        nil -> elem(defaults, idx)
        :transparent -> <<>>
        bin when is_binary(bin) -> bin
      end
    end)
    |> List.to_tuple()
  end

  # Neutral fallback — used when no theme has been installed. Keeps
  # the TUI renderable even in a fresh iex session without any app
  # boot. Values picked to be legible on both light and dark
  # terminals: transparent bg (host terminal shows through), warm
  # off-white fg.
  defp fallback_tuple do
    transparent = <<>>
    fg = rgba(0.90, 0.90, 0.90)
    fg_dim = rgba(0.65, 0.65, 0.68)
    fg_muted = rgba(0.50, 0.50, 0.55)
    accent = rgba(0.50, 0.80, 1.00)
    border = rgba(0.35, 0.35, 0.40)
    selection_bg = rgba(0.22, 0.28, 0.40)
    error = rgba(0.95, 0.40, 0.45)
    warning = rgba(0.95, 0.80, 0.35)
    success = rgba(0.45, 0.85, 0.50)
    info = rgba(0.45, 0.82, 0.90)
    heading = rgba(0.95, 0.88, 0.55)
    link = rgba(0.60, 0.78, 0.98)
    code = rgba(0.78, 0.85, 1.00)
    keyword = rgba(0.85, 0.55, 0.90)
    string = rgba(0.72, 0.88, 0.60)

    {
      transparent,
      transparent,
      fg,
      fg_dim,
      fg_muted,
      selection_bg,
      accent,
      border,
      error,
      warning,
      success,
      info,
      heading,
      link,
      code,
      keyword,
      string
    }
  end

  defp rgba(r, g, b),
    do: <<r::float-32-little, g::float-32-little, b::float-32-little, 1.0::float-32-little>>
end
