defmodule Egghead.TUI.Header do
  @moduledoc """
  Shared header bar rendered at the top of every screen.

  Layout:

      egghead · <context>                Records  Chat

  Left: app name + screen-specific context (record count, room
  info, etc.). Right: tab labels — the active screen is bold,
  the inactive one dim. The Chat tab is omitted entirely when
  no LLM providers are configured.

  F1 switches to Records, F2 switches to Chat. The tab labels
  double as a visual affordance for discoverability.
  """

  import Egghead.OpenTUI.View

  alias Egghead.OpenTUI.{Attrs, Colors}

  @doc """
  Render the header bar.

  * `active` — `:records` or `:chat`
  * `context` — a short string for the center (e.g. "durable · 42 records")
  * `width` — terminal columns
  * `providers?` — whether LLM providers are configured (hides Chat tab when false)
  """
  @spec render(atom(), String.t(), pos_integer(), boolean()) :: Egghead.OpenTUI.View.tree()
  def render(active, context, width, providers?) do
    left = " egghead · #{context}"
    tabs = tab_labels(active, providers?)
    right = tabs_text(tabs)
    right_w = String.length(right)

    pad_size = max(width - String.length(left) - right_w, 0)

    children =
      [
        text(left,
          width: String.length(left),
          fg: Colors.white(),
          bg: Colors.selected_bg()
        ),
        text(String.duplicate(" ", pad_size),
          width: pad_size,
          fg: Colors.white(),
          bg: Colors.selected_bg()
        )
      ] ++ tab_nodes(tabs)

    hbox([height: 1], children)
  end

  defp tab_labels(active, providers?) do
    tabs = [{:records, "Records"}]
    tabs = if providers?, do: tabs ++ [{:chat, "Chat"}], else: tabs

    Enum.map(tabs, fn {id, label} ->
      {label, id == active}
    end)
  end

  defp tabs_text(tabs) do
    tabs
    |> Enum.map(fn {label, _active?} -> label end)
    |> Enum.join("  ")
    |> Kernel.<>(" ")
  end

  defp tab_nodes(tabs) do
    nodes =
      tabs
      |> Enum.with_index()
      |> Enum.flat_map(fn {{label, active?}, idx} ->
        spacer =
          if idx > 0 do
            [text("  ", width: 2, fg: Colors.dim(), bg: Colors.selected_bg())]
          else
            []
          end

        node =
          if active? do
            text(label,
              width: String.length(label),
              fg: Colors.white(),
              bg: Colors.selected_bg(),
              attrs: Attrs.bold()
            )
          else
            text(label,
              width: String.length(label),
              fg: Colors.dim(),
              bg: Colors.selected_bg()
            )
          end

        spacer ++ [node]
      end)

    nodes ++ [text(" ", width: 1, fg: Colors.white(), bg: Colors.selected_bg())]
  end
end
