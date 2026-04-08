defmodule Egghead.OpenTUI.Layout do
  @moduledoc """
  Layout engine for the OpenTUI view tree.

  `arrange/2` walks a view tree and returns a flat list of
  `{leaf, rect}` pairs in draw order. This is what
  `Egghead.OpenTUI.Renderer.draw/3` consumes.

  ## Layout model

  The view tree is a nested set of `:vbox`, `:hbox`, `:overlay`
  containers and `:text` / `:fill` leaves. Containers don't
  render — only leaves produce bridge calls. The tree is
  arranged in two passes:

    * **measure** (post-order): each node reports its desired
      size. Leaves use their fixed `:width`/`:height` if set,
      otherwise their natural size (text length × 1, fill = 0).
      Containers without `:flex` sum their children along the
      main axis. Containers with `:flex` along the parent's
      main axis report their flex weight as the special atom
      `:flex` instead of a fixed size.
    * **arrange** (pre-order): given a parent rectangle,
      allocate fixed-size children first, distribute leftover
      proportional to flex weights, recurse into containers
      with their assigned rect.

  This is **not** real flexbox. There is no shrink, no wrap,
  no cross-axis alignment. It does just enough to express a
  vertical stack with horizontally-split children plus modal
  overlays — the common shapes for full-screen TUI layouts.
  """

  @type rect ::
          {x :: non_neg_integer(), y :: non_neg_integer(),
           w :: pos_integer(), h :: pos_integer()}

  @type tree :: Egghead.OpenTUI.View.tree()
  @type leaf_rect :: {tree(), rect()}

  @doc """
  Arrange a view tree inside `viewport` and return a flat list
  of `{leaf, rect}` pairs in draw order. Containers themselves
  don't appear in the output — only leaves (`:text`, `:fill`).

  The leaves come out in the order the renderer should draw
  them, which for `:overlay` means later children appear later
  in the list (and so paint on top).
  """
  @spec arrange(tree(), rect()) :: [leaf_rect()]
  def arrange(tree, {_x, _y, _w, _h} = viewport) do
    arrange_node(tree, viewport) |> List.flatten()
  end

  defp arrange_node(:nothing, _rect), do: []

  defp arrange_node({:text, _content, _opts} = leaf, rect), do: [{leaf, rect}]

  defp arrange_node({:fill, _opts} = leaf, rect), do: [{leaf, rect}]

  defp arrange_node({:overlay, children}, rect) do
    Enum.map(children, &arrange_node(&1, rect))
  end

  defp arrange_node({:vbox, _opts, children}, {x, y, w, h}) do
    fixed = Enum.map(children, &fixed_main(&1, :vertical))
    flex = Enum.map(children, &flex_weight_axis(&1, :vertical))
    rects = distribute(fixed, flex, h)

    {acc, _} =
      Enum.zip(children, rects)
      |> Enum.reduce({[], y}, fn {child, child_h}, {acc, cy} ->
        child_rect = {x, cy, w, child_h}
        {[arrange_node(child, child_rect) | acc], cy + child_h}
      end)

    Enum.reverse(acc)
  end

  defp arrange_node({:hbox, _opts, children}, {x, y, w, h}) do
    fixed = Enum.map(children, &fixed_main(&1, :horizontal))
    flex = Enum.map(children, &flex_weight_axis(&1, :horizontal))
    rects = distribute(fixed, flex, w)

    {acc, _} =
      Enum.zip(children, rects)
      |> Enum.reduce({[], x}, fn {child, child_w}, {acc, cx} ->
        child_rect = {cx, y, child_w, h}
        {[arrange_node(child, child_rect) | acc], cx + child_w}
      end)

    Enum.reverse(acc)
  end

  # The fixed size of a child along the parent's main axis.
  # Returns 0 for flex children (which take leftover space).
  defp fixed_main({:vbox, opts, _}, :vertical), do: Map.get(opts, :height, 0)
  defp fixed_main({:hbox, opts, _}, :horizontal), do: Map.get(opts, :width, 0)
  defp fixed_main({:vbox, opts, _}, :horizontal), do: Map.get(opts, :width, 0)
  defp fixed_main({:hbox, opts, _}, :vertical), do: Map.get(opts, :height, 0)
  defp fixed_main({:text, _content, opts}, :vertical), do: Map.get(opts, :height, 1)
  defp fixed_main({:text, content, opts}, :horizontal),
    do: Map.get(opts, :width, String.length(content))
  defp fixed_main({:fill, opts}, :vertical), do: Map.get(opts, :height, 0)
  defp fixed_main({:fill, opts}, :horizontal), do: Map.get(opts, :width, 0)
  defp fixed_main({:overlay, _children}, _), do: 0
  defp fixed_main(:nothing, _), do: 0

  # The flex weight along the parent's main axis. 0 means "not flex".
  defp flex_weight_axis(node, _axis) do
    case node do
      {tag, opts, _} when tag in [:vbox, :hbox] -> Map.get(opts, :flex, 0)
      {:text, _, opts} -> Map.get(opts, :flex, 0)
      {:fill, opts} -> Map.get(opts, :flex, 0)
      _ -> 0
    end
  end

  # Allocate `total` units across N children. Each child has a
  # fixed size and a flex weight. Fixed sizes are honored first;
  # leftover is distributed proportionally to flex weight.
  # Rounding remainder goes to the LAST flex child so totals
  # match exactly. Children with neither fixed nor flex get 0.
  defp distribute(fixed_sizes, flex_weights, total) do
    fixed_total = Enum.sum(fixed_sizes)
    flex_total = Enum.sum(flex_weights)
    leftover = max(total - fixed_total, 0)

    sizes =
      Enum.zip(fixed_sizes, flex_weights)
      |> Enum.map(fn
        {fixed, 0} ->
          fixed

        {_fixed, weight} when flex_total > 0 ->
          div(leftover * weight, flex_total)

        {fixed, _} ->
          fixed
      end)

    # Push the rounding remainder onto the last flex slot.
    current_total = Enum.sum(sizes)
    remainder = total - current_total

    if remainder == 0 or flex_total == 0 do
      sizes
    else
      add_remainder_to_last_flex(sizes, flex_weights, remainder)
    end
  end

  defp add_remainder_to_last_flex(sizes, weights, remainder) do
    last_flex_index =
      weights
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {w, i} -> if w > 0, do: i, else: nil end)

    case last_flex_index do
      nil ->
        sizes

      i ->
        List.update_at(sizes, i, &(&1 + remainder))
    end
  end
end
