defmodule Egghead.TUI.ChatRender do
  @moduledoc """
  Renders chat-mode entries (messages, tool-call actions, system info,
  in-progress streams) into styled terminal lines.

  Entry shapes:

      {:message, %{nick, body, color, usage, ts, agent_id?}}
      {:action,  %{nick, text, color, ts}}              # /me-style tool calls
      {:system,  %{text, kind, ts}}                     # info / warning
      {:in_progress, %{nick, body, agent_id}}           # live streaming

  Each entry renders to one or more `{string, style}` tuples — the same
  shape that the rest of the TUI consumes.
  """

  alias TermUI.Renderer.Style
  alias Egghead.TUI.Markdown
  alias Egghead.TUI.Theme

  @nick_min_width 8

  @spec render_entries(list(), pos_integer()) :: [{String.t(), Style.t()}]
  def render_entries(entries, width) when is_list(entries) and width > 0 do
    nick_col = compute_nick_col(entries)
    Enum.flat_map(entries, &render_entry(&1, width, nick_col))
  end

  def render_entries(_, _), do: []

  # --- Per-entry rendering ---

  defp render_entry({:message, %{nick: nick, body: body} = m}, width, nick_col) do
    body_width = max(10, width - nick_col - 3)
    body_lines = Markdown.render(body || "", body_width)
    nick_color = Map.get(m, :color, :user)
    nick_style = nick_style_for(nick_color, m)

    pad_nick = String.pad_leading(nick, nick_col)
    blank_nick = String.duplicate(" ", nick_col)

    case body_lines do
      [] ->
        [{" " <> pad_nick <> " │ ", nick_style}, {"", nil}]

      [{first_text, first_style} | rest] ->
        first =
          {" " <> pad_nick <> " │ " <> first_text,
           merge_styles(nick_style, first_style)}

        more =
          Enum.map(rest, fn {t, s} ->
            {" " <> blank_nick <> " │ " <> t, s || Theme.normal()}
          end)

        [first | more] ++ [{"", nil}]
    end
  end

  defp render_entry({:in_progress, %{nick: nick, body: body, agent_id: agent_id}}, width, nick_col) do
    body_width = max(10, width - nick_col - 3)
    body_lines = Markdown.render((body || "") <> "▌", body_width)
    nick_style = Theme.agent_color(agent_id)

    pad_nick = String.pad_leading(nick, nick_col)
    blank_nick = String.duplicate(" ", nick_col)

    case body_lines do
      [] ->
        [{" " <> pad_nick <> " │ ▌", Theme.muted()}, {"", nil}]

      [{first_text, _} | rest] ->
        first = {" " <> pad_nick <> " │ " <> first_text, nick_style}
        more = Enum.map(rest, fn {t, _} -> {" " <> blank_nick <> " │ " <> t, Theme.muted()} end)
        [first | more]
    end
  end

  defp render_entry({:action, %{nick: nick, text: text} = m}, width, _nick_col) do
    color = Map.get(m, :color, :muted)

    style =
      case color do
        :muted -> Theme.muted()
        _ -> Theme.muted()
      end

    line = " * " <> nick <> " " <> text
    [{String.slice(line, 0, max(1, width)), style}]
  end

  defp render_entry({:system, %{text: text, kind: kind}}, width, _nick_col) do
    style =
      case kind do
        :warning -> Theme.accent()
        _ -> Theme.muted()
      end

    line = " ── " <> text <> " ──"
    [{String.slice(line, 0, max(1, width)), style}]
  end

  defp render_entry(_, _width, _nick_col), do: []

  # --- Style helpers ---

  defp nick_style_for(:user, _m), do: Theme.normal()
  defp nick_style_for(:agent, %{agent_id: id}), do: Theme.agent_color(id)
  defp nick_style_for(:agent, %{nick: nick}), do: Theme.agent_color(nick)
  defp nick_style_for(_, _), do: Theme.normal()

  # The body line might come back from Markdown.render with its own style
  # (e.g. headings, code). For non-text styles preserve them; for default
  # text use the normal text style.
  defp merge_styles(_nick, body_style) when not is_nil(body_style), do: body_style
  defp merge_styles(_nick, _), do: Theme.normal()

  defp compute_nick_col(entries) do
    longest =
      entries
      |> Enum.reduce(0, fn
        {:message, %{nick: n}}, acc -> max(acc, String.length(n))
        {:in_progress, %{nick: n}}, acc -> max(acc, String.length(n))
        _, acc -> acc
      end)

    max(@nick_min_width, longest)
  end
end
