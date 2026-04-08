defmodule Egghead.OpenTUI.Renderer do
  @moduledoc """
  Walks a view tree, computes layout, and emits bridge calls.

  This is the only module above `Bridge` that knows about color
  binaries and frame primitives. Everything upstream — the view
  tree, the layout engine, the runtime, and any callers — works
  with abstract `View.tree` values.

  ## Draw cycle

      Renderer.draw(handle, viewport, tree)
        ├── Bridge.begin_frame(handle)
        ├── Bridge.clear(handle, default_bg)
        ├── Layout.arrange(tree, viewport)        # → [{leaf, rect}, ...]
        ├── for each leaf, draw via the bridge
        └── Bridge.end_frame(handle)
  """

  alias Egghead.OpenTUI.{Bridge, Colors, Layout}

  @type rect :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @doc """
  Render `tree` into the back buffer of `handle`, occupying
  `viewport`. Begins and ends the frame internally.
  """
  @spec draw(non_neg_integer(), rect(), Egghead.OpenTUI.View.tree()) :: :ok
  def draw(handle, {_x, _y, _w, _h} = viewport, tree) do
    :ok = Bridge.begin_frame(handle)
    :ok = Bridge.clear(handle, Colors.bg())

    tree
    |> Layout.arrange(viewport)
    |> Enum.each(fn {leaf, rect} -> draw_leaf(handle, leaf, rect) end)

    :ok = Bridge.end_frame(handle)
    :ok
  end

  # ---- leaves -------------------------------------------------------------

  defp draw_leaf(handle, {:fill, opts}, {x, y, w, h}) when w > 0 and h > 0 do
    bg = Map.get(opts, :bg, Colors.bg())
    :ok = Bridge.fill_rect(handle, x, y, w, h, bg)
  end

  defp draw_leaf(_handle, {:fill, _opts}, _rect), do: :ok

  defp draw_leaf(handle, {:text, content, opts}, {x, y, w, h})
       when w > 0 and h > 0 do
    fg = Map.get(opts, :fg, Colors.white())
    bg = Map.get(opts, :bg, :transparent)

    # Optional bg fill behind the text rect, so multi-row text
    # leaves with a background look correct.
    case bg do
      :transparent -> :ok
      bin when is_binary(bin) -> :ok = Bridge.fill_rect(handle, x, y, w, h, bin)
    end

    bg_for_text =
      case bg do
        :transparent -> Colors.transparent()
        bin -> bin
      end

    # `:text` is a single-row primitive: only the first row of
    # the assigned rect is painted. Multi-row text content should
    # be expressed as a vbox of single-row `:text` leaves so each
    # row gets its own y coordinate. We still paint the top row
    # for `h > 1` so the leaf isn't silently invisible.
    line = truncate(content, w)
    :ok = Bridge.draw_text(handle, line, x, y, fg, bg_for_text, 0)
  end

  defp draw_leaf(_handle, {:text, _content, _opts}, _rect), do: :ok

  # ---- helpers ------------------------------------------------------------

  defp truncate(str, max) when is_binary(str) and is_integer(max) and max > 0 do
    if String.length(str) <= max do
      str
    else
      String.slice(str, 0, max)
    end
  end

  defp truncate(_str, _max), do: ""
end
