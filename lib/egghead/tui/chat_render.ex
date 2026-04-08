defmodule Egghead.TUI.ChatRender do
  @moduledoc """
  Renders chat-mode entries (messages, tool-call actions, system info,
  thinking indicators, in-progress streams) into styled terminal lines.

  Entry shapes:

      {:message,     %{nick, body, color, usage, ts, agent_id?}}
      {:action,      %{nick, text, color, ts}}            # /me-style tool calls
      {:system,      %{text, kind, ts}}                   # info / warning
      {:thinking,    %{nick, agent_id, frame}}            # animated ellipsis
      {:in_progress, %{nick, body, agent_id}}             # live streaming

  Each entry renders to one or more lines. A line is either:

    * a single-style tuple: `{string, style}`
    * a multi-span list:    `[{string, style}, ...]`

  The transcript renderer in `Egghead.TUI.App` handles both shapes.
  """

  alias Egghead.TUI.Markdown
  alias Egghead.TUI.Theme

  @nick_min_width 8
  # Reserved space for the right-aligned " HH:MM" timestamp.
  @ts_width 6

  @spec render_entries(list(), pos_integer()) :: list()
  def render_entries(entries, width) when is_list(entries) and width > 0 do
    nick_col = compute_nick_col(entries)
    Enum.flat_map(entries, &render_entry(&1, width, nick_col))
  end

  def render_entries(_, _), do: []

  # --- Per-entry rendering ---

  defp render_entry({:message, %{nick: nick, body: body} = m}, width, nick_col) do
    # Reserve 1 extra cell so the timestamp never butts against the body.
    body_width = max(10, width - nick_col - 3 - @ts_width - 1)
    body_lines = (body || "") |> Markdown.render(body_width) |> trim_trailing_blanks()

    nick_color = Map.get(m, :color, :user)
    nick_style = nick_style_for(nick_color, m)
    body_override = if nick_color == :user, do: Theme.md_bold(), else: nil

    pad_nick = String.pad_leading(nick, nick_col)
    blank_nick = String.duplicate(" ", nick_col)

    ts_label = format_ts(Map.get(m, :ts))

    case body_lines do
      [] ->
        [first_line_with_ts(" " <> pad_nick <> " │ ", "", nick_style, width, ts_label)]

      [{first_text, first_style} | rest] ->
        body_style = body_override || merge_styles(nick_style, first_style)

        first =
          first_line_with_ts(
            " " <> pad_nick <> " │ ",
            first_text,
            body_style,
            width,
            ts_label,
            nick_style
          )

        more =
          Enum.map(rest, fn {t, s} ->
            line_style = body_override || s || Theme.normal()
            {" " <> blank_nick <> " │ " <> t, line_style}
          end)

        [first | more]
    end
  end

  defp render_entry({:thinking, %{nick: nick, agent_id: agent_id, frame: frame}}, width, _nick_col) do
    dots = thinking_dots(frame)
    style = Theme.agent_color(agent_id)
    line = " * " <> nick <> " is thinking" <> dots
    [{String.slice(line, 0, max(1, width)), style}]
  end

  defp render_entry({:in_progress, %{nick: nick, body: body, agent_id: agent_id}}, width, nick_col) do
    # Reserve 1 extra cell so the timestamp never butts against the body.
    body_width = max(10, width - nick_col - 3 - @ts_width - 1)
    body_lines = ((body || "") <> "▌") |> Markdown.render(body_width) |> trim_trailing_blanks()
    nick_style = Theme.agent_color(agent_id)

    pad_nick = String.pad_leading(nick, nick_col)
    blank_nick = String.duplicate(" ", nick_col)

    case body_lines do
      [] ->
        [{" " <> pad_nick <> " │ ▌", Theme.muted()}]

      [{first_text, _} | rest] ->
        first = {" " <> pad_nick <> " │ " <> first_text, nick_style}
        more = Enum.map(rest, fn {t, _} -> {" " <> blank_nick <> " │ " <> t, Theme.muted()} end)
        [first | more]
    end
  end

  defp render_entry({:action, %{nick: nick, text: text}}, width, _nick_col) do
    line = " * " <> nick <> " " <> text
    [{String.slice(line, 0, max(1, width)), Theme.muted()}]
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

  # --- Multi-span helpers ---

  # Build the first line of a message: a "nick │ body" line with the
  # timestamp right-aligned at the line's far edge. If no timestamp,
  # falls back to the simple single-style tuple.
  defp first_line_with_ts(prefix, body, body_style, width, ts_label, nick_style \\ nil) do
    if ts_label == "" do
      {prefix <> body, body_style}
    else
      used = String.length(prefix) + String.length(body)
      pad_len = max(0, width - used - String.length(ts_label))
      pad = String.duplicate(" ", pad_len)

      [
        {prefix, nick_style || body_style},
        {body, body_style},
        {pad, nil},
        {ts_label, Theme.muted()}
      ]
    end
  end

  # --- Style helpers ---

  defp nick_style_for(:user, _m), do: Theme.user()
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

  defp thinking_dots(frame) when is_integer(frame) do
    case rem(frame, 4) do
      0 -> ""
      1 -> "."
      2 -> ".."
      3 -> "..."
    end
  end

  defp thinking_dots(_), do: ""

  # Markdown.render appends a `{"", nil}` line after each paragraph.
  # In chat-mode rendering we want messages flush against each other,
  # so strip any trailing blank lines from a body's render result.
  defp trim_trailing_blanks(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&blank_line?/1)
    |> Enum.reverse()
  end

  defp blank_line?({"", _}), do: true
  defp blank_line?({nil, _}), do: true
  defp blank_line?(_), do: false

  defp format_ts(%DateTime{} = dt) do
    {h, m, _} = {dt.hour, dt.minute, dt.second}
    " " <> two(h) <> ":" <> two(m)
  end

  defp format_ts(_), do: ""

  defp two(n) when n < 10, do: "0" <> Integer.to_string(n)
  defp two(n), do: Integer.to_string(n)
end
