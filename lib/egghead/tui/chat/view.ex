defmodule Egghead.TUI.Chat.View do
  @moduledoc """
  Pure view function for the chat screen.

  Layout:

      ┌──────────────────────────┬────────┐
      │ egghead · #room          │Rec Chat│  header (1 row)
      ├──────────────────────────┼────────┤
      │ user: hi                 │● scout │
      │ scout: hello             │  1.2k↓ │  transcript + sidebar
      │ scout:▌                  │  ░░ 1% │
      │                          │○ index │
      ├──────────────────────────┴────────┤
      │ ❯ what about activation?▌         │  input row (1 row)
      ├───────────────────────────────────┤
      │ CHAT │ ⏎ send │ /cmd │ F1 │ ^q   │  status bar (1 row)
      └───────────────────────────────────┘

  Sidebar width is stepped: 22 cols at width >= 100, 18 cols
  at 80–99, hidden below 80 (narrow mode shows a one-line
  agent summary strip instead).
  """

  import Egghead.OpenTUI.View

  alias Egghead.Chat.Stream
  alias Egghead.OpenTUI.{Attrs, Colors, EditBuffer}
  alias Egghead.Theme.Roles
  alias Egghead.TUI.Chat.{Entry, Mentions.Token, Model, Paste}
  alias Egghead.TUI.{Completion, MarkdownCache, SelectList, ThemePicker}
  alias Model.AgentPresence

  @prompt "❯ "
  @continuation "  "
  @max_input_rows 8

  @spec render(Model.t()) :: Egghead.OpenTUI.View.tree()
  def render(%Model{} = model) do
    width = model.width
    height = model.height
    sb_width = sidebar_width(width)

    prompt_w = String.length(@prompt)
    text_w = max(width - prompt_w, 1)
    input_height = clamp(EditBuffer.visual_line_count(model.input, text_w), 1, @max_input_rows)
    dd_height = dropdown_height(model)
    picker_h = picker_height(model)
    # header(1) + input_border(1) + input + spacer(1) + status(1) = 4 + input
    chrome = 4 + input_height + dd_height + picker_h
    # In narrow mode, the agent summary strip takes 1 row.
    narrow_strip = if sb_width == 0 and model.agents != [], do: 1, else: 0
    transcript_height = max(height - chrome - narrow_strip, 1)
    transcript_width = if sb_width > 0, do: width - sb_width, else: width

    main_region =
      if sb_width > 0 do
        # 1-col separator between transcript and sidebar.
        sep =
          vbox(
            [width: 1, height: transcript_height],
            List.duplicate(text("│", height: 1, fg: Colors.muted()), transcript_height)
          )

        hbox([height: transcript_height], [
          transcript_region(model, transcript_width - 1, transcript_height),
          sep,
          sidebar(model.agents, sb_width, transcript_height)
        ])
      else
        transcript_region(model, transcript_width, transcript_height)
      end

    hr = text(String.duplicate("─", width), height: 1, fg: Colors.muted())

    children =
      [header(model, width), main_region] ++
        narrow_strip_node(model, width, narrow_strip) ++
        [hr, input_box(model, width, input_height)] ++
        dropdown_node(model, width, dd_height) ++
        picker_node(model, width) ++
        [text("", height: 1), status_bar(model, width)]

    vbox(children)
  end

  # Theme picker and action picker share the same inline slot
  # above the status bar. They are mutually exclusive by
  # construction (the refresh_completion / picker routing in the
  # Update module ensures only one is open at a time).
  defp picker_height(%Model{theme_picker: p}) when not is_nil(p), do: ThemePicker.height(p)
  defp picker_height(%Model{action_picker: {_, list}}), do: SelectList.height(list)
  defp picker_height(_), do: 0

  defp picker_node(%Model{theme_picker: p}, width) when not is_nil(p),
    do: [ThemePicker.view(p, width)]

  defp picker_node(%Model{action_picker: {_, list}}, width), do: [SelectList.view(list, width)]
  defp picker_node(_, _), do: []

  # Stepped sidebar width: 22 at >= 100, 18 at 80–99, 0 below.
  defp sidebar_width(w) when w >= 100, do: 22
  defp sidebar_width(w) when w >= 80, do: 18
  defp sidebar_width(_), do: 0

  defp dropdown_height(%Model{completion: completion}), do: Completion.View.height(completion)

  defp dropdown_node(%Model{completion: %Completion{} = completion}, width, h) when h > 0 do
    [Completion.View.render(completion, width, h)]
  end

  defp dropdown_node(_, _, _), do: []

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  # ---- header --------------------------------------------------------------

  defp header(model, width) do
    context = "##{model.room_id || "—"} · #{length(model.transcript)} msgs"

    Egghead.TUI.Header.render(:chat, context, width, model.providers?)
  end

  # ---- transcript ----------------------------------------------------------

  # IRC-style nick gutter: fixed-width left column with
  # right-aligned nicks, a colored dot identifier, and the
  # message body to the right. Consecutive messages from the
  # same sender collapse the nick.
  @nick_gutter 14

  defp transcript_region(%Model{} = model, width, height) do
    # Reserve 1 col on the right for the scrollbar track.
    content_w = max(width - 1, 1)
    rows = render_transcript_rows(model, content_w)
    total = length(rows)

    # scroll == 0 means "pinned to bottom" (newest visible).
    # Positive scroll means "N lines from the bottom".
    max_scroll = max(total - height, 0)
    scroll = min(model.scroll, max_scroll)

    # Compute the viewport offset from the top.
    top =
      if total <= height do
        0
      else
        total - height - scroll
      end

    visible =
      rows
      |> Enum.drop(top)
      |> Enum.take(height)

    padded_rows = pad_top_tree(visible, height, content_w)
    transcript_col = vbox([width: content_w, height: height], padded_rows)

    # Scrollbar as a separate 1-col column on the right.
    {bar_start, bar_size} =
      if total > height do
        size = max(1, round(height * height / total))
        travel = max(0, height - size)
        pos = if max_scroll > 0, do: round((max_scroll - scroll) / max_scroll * travel), else: 0
        {pos, size}
      else
        {0, 0}
      end

    sb_rows =
      Enum.map(0..(height - 1), fn idx ->
        is_thumb = bar_size > 0 and idx >= bar_start and idx < bar_start + bar_size
        sb_char = if is_thumb, do: "▐", else: " "
        sb_fg = if is_thumb, do: Colors.muted(), else: Colors.bg()
        text(sb_char, height: 1, width: 1, fg: sb_fg)
      end)

    scrollbar_col = vbox([width: 1, height: height], sb_rows)

    hbox([width: width, height: height], [transcript_col, scrollbar_col])
  end

  defp render_transcript_rows(%Model{} = model, width) do
    body_width = max(width - @nick_gutter - 1, 1)
    active_target = Model.active_link(model)

    transcript_rows =
      model.transcript
      |> collapse_nicks()
      |> group_agent_runs()
      |> Enum.flat_map(fn
        {:run, entries_with_nicks} ->
          agent_run_to_rows(entries_with_nicks, body_width, width, active_target)

        {:single, entry, show_nick?} ->
          entry_to_rows(entry, show_nick?, body_width, width, active_target)
      end)

    stream_rows =
      model.streams
      |> Map.values()
      |> Enum.sort_by(& &1.started_at)
      |> Enum.flat_map(fn stream ->
        stream_to_rows(stream, body_width, width, model.anim_frame)
      end)

    transcript_rows ++ stream_rows
  end

  # Group consecutive `:agent` entries from the same sender into
  # runs for unified markdown rendering. Non-agent entries (actions,
  # system, handoff) are always emitted as singles — they must never
  # land in a run or they'll get rendered as markdown chat instead
  # of their proper `/me`-style format.
  defp group_agent_runs(nick_tagged_entries) do
    {groups, pending} =
      Enum.reduce(nick_tagged_entries, {[], []}, fn {entry, show_nick?} = tagged, {groups, acc} ->
        case {entry.kind, acc} do
          # Agent entry, empty accumulator — start a new run.
          {:agent, []} ->
            {groups, [tagged]}

          # Agent entry, continuing a run from the same sender.
          {:agent, [{%Entry{kind: :agent, sender_id: sid}, _} | _]}
          when entry.sender_id == sid ->
            {groups, acc ++ [tagged]}

          # Agent entry from a different sender — flush old run, start new.
          {:agent, _run} ->
            {groups ++ [flush_run(acc)], [tagged]}

          # Non-agent entry — flush any pending run, emit as single.
          {_, []} ->
            {groups ++ [{:single, entry, show_nick?}], []}

          {_, _run} ->
            {groups ++ [flush_run(acc), {:single, entry, show_nick?}], []}
        end
      end)

    # Flush any trailing pending run.
    case pending do
      [] -> groups
      _ -> groups ++ [flush_run(pending)]
    end
  end

  defp flush_run([{entry, show_nick?}]) when entry.kind != :agent,
    do: {:single, entry, show_nick?}

  defp flush_run(run), do: {:run, run}

  # Render a run of consecutive agent entries from the same sender
  # as a stack of markdown blocks. The nick appears on the first row;
  # continuation rows get blank gutter.
  #
  # Each entry was committed on a `\n\n` paragraph boundary, so we
  # render each one independently and stack the rows, interleaving a
  # blank row between entries to reproduce the visual spacing of a
  # single merged render. Per-entry rendering lets `MarkdownCache`
  # hit on every draw for every already-committed entry — a streaming
  # agent only incurs one Earmark pass per new paragraph, not one per
  # paragraph per draw.
  defp agent_run_to_rows(entries_with_nicks, body_w, full_w, active_target) do
    [{first_entry, show_nick?} | _] = entries_with_nicks

    nick =
      if show_nick?,
        do: nick_cell(first_entry.sender_name, :agent, first_entry.sender_id),
        else: blank_nick()

    md_rows =
      entries_with_nicks
      |> Enum.map(fn {e, _} ->
        e.text |> MarkdownCache.render(body_w) |> trim_trailing_empty()
      end)
      |> Enum.intersperse([[]])
      |> Enum.concat()

    wrap_markdown(nick, md_rows, full_w, nil, active_target)
  end

  # Tag each entry with whether its nick should be displayed.
  # Consecutive entries from the same sender_id AND kind collapse.
  # Different kinds (e.g. :action → :agent) always re-show the nick
  # because the gutter symbol changes.
  defp collapse_nicks(entries) do
    entries
    |> Enum.reduce({{nil, nil}, []}, fn entry, {{prev_id, prev_kind}, acc} ->
      same_sender? = entry.sender_id == prev_id and entry.sender_id != nil
      same_kind? = entry.kind == prev_kind
      show? = not (same_sender? and same_kind?)
      {{entry.sender_id || prev_id, entry.kind}, [{entry, show?} | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp entry_to_rows(%Entry{kind: :user} = e, show_nick?, body_w, full_w, active_target) do
    nick = if show_nick?, do: nick_cell(e.sender_name, :user, e.sender_id), else: blank_nick()
    md_rows = e.text |> MarkdownCache.render(body_w) |> trim_trailing_empty()
    wrap_markdown(nick, md_rows, full_w, Roles.user_msg_bg(), active_target)
  end

  defp entry_to_rows(%Entry{kind: :action} = e, _show_nick?, body_w, full_w, _active_target) do
    nick = gutter_symbol("*")
    wrap_body(nick, "#{e.sender_name} #{e.text}", body_w, full_w, Colors.muted(), nil)
  end

  defp entry_to_rows(%Entry{kind: :denial} = e, _show_nick?, body_w, full_w, _active_target) do
    nick = gutter_symbol("⚠")
    body = "#{e.sender_name} #{e.text}"
    wrap_body(nick, body, body_w, full_w, Colors.yellow(), nil)
  end

  defp entry_to_rows(%Entry{kind: :system} = e, _show_nick?, body_w, full_w, active_target) do
    nick = gutter_symbol("—")
    md_rows = e.text |> MarkdownCache.render(body_w) |> trim_trailing_empty()
    wrap_markdown(nick, md_rows, full_w, nil, active_target, Colors.dim())
  end

  defp entry_to_rows(%Entry{kind: :handoff} = e, _show_nick?, body_w, full_w, active_target) do
    nick = gutter_symbol("»")
    md_rows = e.text |> MarkdownCache.render(body_w) |> trim_trailing_empty()
    wrap_markdown(nick, md_rows, full_w, nil, active_target)
  end

  # While an agent is composing, show an animated typing indicator.
  # When the buffer is empty (agent is executing tools, not typing),
  # show nothing — the action entries speak for themselves.
  defp stream_to_rows(%Stream{} = stream, body_w, full_w, anim_frame) do
    if Stream.has_text?(stream) do
      nick = nick_cell(stream.name, :agent, stream.agent_id)
      dots = typing_indicator(anim_frame)
      wrap_body(nick, dots, body_w, full_w, Colors.muted(), nil)
    else
      []
    end
  end

  # Animated typing indicator: cycles through ·, ··, ··· like
  # iMessage / WhatsApp composing state.
  defp typing_indicator(frame) do
    n = rem(frame, 3) + 1
    String.duplicate("·", n)
  end

  # A nick cell: "  ● name " right-aligned in the gutter, with
  # a colored dot. The dot color is deterministic per sender_id.
  defp nick_cell(name, kind, sender_id) do
    dot_color = if kind == :user, do: Colors.cyan(), else: agent_color(sender_id || name)
    truncated = String.slice(name || "", 0, @nick_gutter - 4)
    # Right-align: pad on the left so "● name " is flush right.
    label = "● #{truncated} "
    padded = String.pad_leading(label, @nick_gutter)

    {padded, dot_color, true}
  end

  defp blank_nick do
    {String.duplicate(" ", @nick_gutter), nil, false}
  end

  defp gutter_symbol(sym) do
    label = "#{sym} "
    padded = String.pad_leading(label, @nick_gutter)
    {padded, Colors.muted(), false}
  end

  # Wrap a message body and pair each line with its nick (first
  # line) or blank gutter (continuation lines). Returns a list
  # of hbox tree nodes.
  defp wrap_body({nick_str, dot_color, has_nick?}, body_text, body_w, full_w, fg, bg) do
    lines =
      body_text
      |> String.split("\n")
      |> Enum.flat_map(fn para -> soft_wrap(para, body_w) end)

    bg_opts = if(bg, do: [bg: bg], else: [])

    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      gutter =
        if idx == 0 and has_nick? do
          nick_node(nick_str, dot_color, bg)
        else
          text(String.duplicate(" ", @nick_gutter), [width: @nick_gutter] ++ bg_opts)
        end

      sep = text(" ", [width: 1, fg: Colors.muted()] ++ bg_opts)
      body_node = text(pad_to(line, full_w - @nick_gutter - 1), [height: 1, fg: fg] ++ bg_opts)

      hbox([height: 1], [gutter, sep, body_node])
    end)
  end

  # Wrap markdown-rendered span rows with the nick gutter. Each
  # span row from `Markdown.render/2` becomes an hbox: gutter +
  # separator + styled span leaves. The first row gets the nick;
  # continuation rows get blank gutter.
  defp wrap_markdown(
         {nick_str, dot_color, has_nick?},
         md_rows,
         full_w,
         bg,
         active_target,
         fg_override \\ nil
       ) do
    bg_opts = if(bg, do: [bg: bg], else: [])
    body_w = full_w - @nick_gutter - 1

    md_rows
    |> Enum.with_index()
    |> Enum.map(fn {span_row, idx} ->
      gutter =
        if idx == 0 and has_nick? do
          nick_node(nick_str, dot_color, bg)
        else
          text(String.duplicate(" ", @nick_gutter), [width: @nick_gutter] ++ bg_opts)
        end

      sep = text(" ", [width: 1, fg: Colors.muted()] ++ bg_opts)

      span_leaves =
        Enum.map(span_row, fn span ->
          fg = fg_override || span.fg || Colors.white()
          highlight? = active_target != nil and span_is_wikilink?(span, active_target)

          opts =
            if highlight? do
              [width: String.length(span.text), fg: fg, attrs: Attrs.reverse()] ++ bg_opts
            else
              [width: String.length(span.text), fg: fg, attrs: span.attrs] ++ bg_opts
            end

          text(span.text, opts)
        end)

      used = Enum.reduce(span_row, 0, fn span, acc -> acc + String.length(span.text) end)
      pad_w = max(body_w - used, 0)
      pad_leaf = text(String.duplicate(" ", pad_w), [width: pad_w] ++ bg_opts)

      hbox([height: 1], [gutter, sep] ++ span_leaves ++ [pad_leaf])
    end)
  end

  defp span_is_wikilink?(span, target) do
    Map.get(span, :link) == {:wikilink, target}
  end

  # Render the nick gutter as an hbox: padding + dot + name.
  # The dot gets its own color; the name is bold white.
  # `bg` is applied to all sub-leaves so user-message tint
  # extends across the full row.
  defp nick_node(nick_str, dot_color, bg) do
    bg_opts = if(bg, do: [bg: bg], else: [])

    # Split at the "●" to color just the dot.
    case String.split(nick_str, "●", parts: 2) do
      [leading, trailing] ->
        hbox([width: @nick_gutter, height: 1], [
          text(leading, [width: String.length(leading), fg: Colors.dim()] ++ bg_opts),
          text("●", [width: 1, fg: dot_color] ++ bg_opts),
          text(
            trailing,
            [width: String.length(trailing), fg: Colors.white(), attrs: Attrs.bold()] ++ bg_opts
          )
        ])

      _ ->
        text(nick_str, [width: @nick_gutter, fg: Colors.dim()] ++ bg_opts)
    end
  end

  # Whitespace-friendly soft wrap. Long single tokens hard-break.
  # Leading whitespace on the input line is preserved verbatim and
  # carried into the first wrapped line so indented content (e.g.
  # pasted code) keeps its shape in the transcript.
  defp soft_wrap("", _width), do: [""]

  defp soft_wrap(text, width) do
    {leading, rest} = pop_leading_spaces(text)
    body_width = max(width - String.length(leading), 1)

    case soft_wrap_body(rest, body_width) do
      [] -> [leading]
      [first | more] -> [leading <> first | more]
    end
  end

  defp pop_leading_spaces(text) do
    leading = text |> String.graphemes() |> Enum.take_while(&(&1 == " ")) |> Enum.join()
    rest = String.replace_prefix(text, leading, "")
    {leading, rest}
  end

  defp soft_wrap_body("", _width), do: [""]

  defp soft_wrap_body(text, width) do
    text
    |> String.split(" ")
    |> Enum.reduce([""], fn word, [current | rest] ->
      cond do
        current == "" and String.length(word) <= width ->
          [word | rest]

        String.length(current) + 1 + String.length(word) <= width ->
          [current <> " " <> word | rest]

        String.length(word) <= width ->
          [word, current | rest]

        true ->
          # Hard-break a token longer than the window.
          chunks = hard_break(word, width)

          acc_with_first =
            case current do
              "" -> rest
              _ -> [current | rest]
            end

          Enum.reverse(chunks) ++ acc_with_first
      end
    end)
    |> Enum.reverse()
  end

  defp hard_break(text, width) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  defp pad_top_tree(rows, height, _width) do
    pad = height - length(rows)

    if pad > 0 do
      blanks = List.duplicate(text("", height: 1), pad)
      blanks ++ rows
    else
      rows
    end
  end

  # Strip trailing empty rows from Markdown.render output.
  # Earmark produces a trailing blank row for every paragraph;
  # in chat bubbles this looks like an unwanted extra newline.
  defp trim_trailing_empty(rows) do
    rows
    |> Enum.reverse()
    |> Enum.drop_while(fn row -> row == [] end)
    |> Enum.reverse()
    |> case do
      [] -> [[]]
      trimmed -> trimmed
    end
  end

  # ---- sidebar ---------------------------------------------------------------

  # Top-aligned: agent count header, then agent cards on a
  # tinted background. Remaining space filled with bg. A 1-col
  # left margin separates content from the left border.
  defp sidebar(agents, sb_width, height) do
    header_label = "  #{length(agents)} Agents"

    header_row =
      text(pad_to(header_label, sb_width),
        height: 1,
        fg: Colors.dim(),
        bg: Roles.sidebar_bg(),
        attrs: Attrs.bold()
      )

    spacer = text(String.duplicate(" ", sb_width), height: 1, bg: Roles.sidebar_bg())

    cards =
      agents
      |> Enum.flat_map(fn a -> agent_card(a, sb_width) end)

    rows = [header_row, spacer | cards] |> Enum.take(height)
    remaining = height - length(rows)

    fill_rows =
      if remaining > 0 do
        List.duplicate(
          text(String.duplicate(" ", sb_width), height: 1, bg: Roles.sidebar_bg()),
          remaining
        )
      else
        []
      end

    vbox([width: sb_width, height: height], rows ++ fill_rows)
  end

  defp agent_card(%AgentPresence{} = a, sb_width) do
    indicator = status_indicator(a)
    # 1-col left margin, then indicator, then space, then name.
    name_raw = " #{indicator} #{a.name}"
    name = truncate_display(name_raw, sb_width)

    {fg, bold?} =
      cond do
        a.muted? -> {Colors.dim(), false}
        a.status == :active -> {Colors.green(), true}
        true -> {Colors.dim(), false}
      end

    name_row =
      text(pad_display(name, sb_width),
        height: 1,
        fg: fg,
        bg: Roles.sidebar_bg(),
        attrs: if(bold?, do: Attrs.bold(), else: 0)
      )

    has_window? = a.ctx_window > 0

    token_label =
      cond do
        has_window? ->
          "   #{format_tokens(a.ctx_tokens)}/#{format_tokens(a.ctx_window)}"

        a.ctx_tokens > 0 ->
          "   #{format_tokens(a.ctx_tokens)} tok"

        true ->
          "   —"
      end

    token_row =
      text(pad_to(truncate_line(token_label, sb_width), sb_width),
        height: 1,
        fg: Colors.dim(),
        bg: Roles.sidebar_bg()
      )

    # Leave 3 chars right margin so e.g. "62.3%" doesn't butt
    # against the screen edge. With no known window, render an
    # honest blank row rather than a fake 0% bar.
    ctx_row =
      if has_window? do
        bar = context_bar(a.ctx_pct, sb_width - 4)

        text(pad_to("   #{bar}", sb_width),
          height: 1,
          fg: Colors.muted(),
          bg: Roles.sidebar_bg()
        )
      else
        text(pad_to("", sb_width), height: 1, bg: Roles.sidebar_bg())
      end

    separator =
      text(String.duplicate(" ", sb_width), height: 1, bg: Roles.sidebar_bg())

    [name_row, token_row, ctx_row, separator]
  end

  defp status_indicator(%AgentPresence{muted?: true}), do: "🔇"
  defp status_indicator(%AgentPresence{status: :active}), do: "●"
  defp status_indicator(_), do: "○"

  # Pad to a fixed display-column width. Needed on sidebar rows
  # where a 2-col-wide emoji (🔇) would cause `pad_to/2`'s
  # grapheme-based count to under-pad the background tint.
  defp pad_display(line, width) do
    used = display_width(line)
    if used >= width, do: line, else: line <> String.duplicate(" ", width - used)
  end

  # Truncate a string so its display width fits within `width`.
  # Grapheme-by-grapheme so a 2-col emoji at the edge doesn't
  # half-render into column overflow.
  defp truncate_display(line, width) do
    line
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn g, {acc, used} ->
      w = grapheme_width(g)
      if used + w > width, do: {:halt, {acc, used}}, else: {:cont, {[g | acc], used + w}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp format_tokens(n), do: "#{n}"

  # A small text-art bar: filled blocks + empty blocks + percentage.
  defp context_bar(pct, width) do
    suffix = " #{:erlang.float_to_binary(pct, decimals: 1)}%"
    bar_width = max(width - String.length(suffix), 2)
    filled = round(pct / 100.0 * bar_width)
    empty = bar_width - filled
    String.duplicate("█", filled) <> String.duplicate("░", empty) <> suffix
  end

  # ---- narrow agent strip ---------------------------------------------------

  # When the sidebar is hidden (width < 80), show a single-line
  # summary strip above the input: "3 agents · 4.2k tok · 1.8%"
  defp narrow_strip_node(%Model{agents: agents}, width, 1) do
    active = Enum.count(agents, &(&1.status == :active))
    total_tok = Enum.reduce(agents, 0, fn a, acc -> acc + a.ctx_tokens end)

    parts =
      ["#{length(agents)} agents"] ++
        if(active > 0, do: ["#{active} active"], else: []) ++
        if(total_tok > 0, do: ["#{format_tokens(total_tok)} tok"], else: [])

    label = " " <> Enum.join(parts, " · ") <> " "
    [text(pad_to(label, width), height: 1, fg: Colors.dim(), bg: Colors.bg())]
  end

  defp narrow_strip_node(_, _, _), do: []

  defp truncate_line(line, width) do
    if String.length(line) > width, do: String.slice(line, 0, width), else: line
  end

  # ---- input ---------------------------------------------------------------

  # Render the EditBuffer as a stack of `input_height` rows. The
  # first visible line carries the `❯ ` prompt; continuation lines
  # are indented to the same width so the buffer hangs under the
  # prompt the way Claude Code's input box does. The cursor leaf
  # is emitted on the cursor row, splitting that row's text at
  # `col` so the renderer can paint a real terminal cursor (same
  # pattern as `Egghead.TUI.Records.View.search/2`).
  defp input_box(%Model{input: buffer} = model, width, input_height) do
    {cursor_row, cursor_col} = EditBuffer.cursor(buffer)
    prompt_w = String.length(@prompt)
    text_w = max(width - prompt_w, 1)
    ghost = ghost_text(model)

    # Build visual rows by soft-wrapping each buffer line. Each
    # visual row tracks: {cells, buf_line_idx, is_first_of_line?,
    # visual_cursor_col_or_nil}.
    visual_rows =
      buffer.lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {cells, buf_idx} ->
        on_cursor_line? = buf_idx == cursor_row
        wrap_input_line(cells, buf_idx, text_w, on_cursor_line?, cursor_col)
      end)

    total_visual = length(visual_rows)

    # Find the visual row containing the cursor.
    cursor_visual_idx =
      Enum.find_index(visual_rows, fn {_, _, _, vc} -> vc != nil end) || 0

    # Scroll so the cursor stays visible.
    visible_top =
      cond do
        total_visual <= input_height -> 0
        cursor_visual_idx >= total_visual - input_height -> total_visual - input_height
        cursor_visual_idx < input_height -> 0
        true -> cursor_visual_idx - input_height + 1
      end

    visible =
      visual_rows
      |> Enum.drop(visible_top)
      |> Enum.take(input_height)

    rows =
      visible
      |> Enum.map(fn {cells, buf_idx, is_first?, vcol} ->
        prompt =
          if buf_idx == 0 and is_first?, do: @prompt, else: @continuation

        on_cursor? = vcol != nil
        col = vcol || 0
        render_input_row(cells, prompt, on_cursor?, col, if(on_cursor?, do: ghost, else: ""))
      end)

    vbox([height: input_height], rows)
  end

  # Soft-wrap a single buffer line's cells into visual rows of
  # `text_w` width. Returns a list of {cells, buf_idx, first?, vcol}.
  defp wrap_input_line(cells, buf_idx, text_w, on_cursor_line?, cursor_col) do
    chunks = EditBuffer.wrap_cells(cells, text_w)

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, chunk_idx} ->
      is_first? = chunk_idx == 0
      chunk_start = chunk_idx * text_w

      vcol =
        if on_cursor_line? and
             cursor_col >= chunk_start and
             cursor_col < chunk_start + text_w do
          cursor_col - chunk_start
        else
          # Cursor at the very end of a line that lands exactly on
          # the wrap boundary — put it on the next (empty) chunk.
          if on_cursor_line? and cursor_col == chunk_start + text_w and
               chunk_idx == length(chunks) - 1 do
            nil
          else
            nil
          end
        end

      # Handle cursor at the very end of the line — it lands at
      # position == length(cells), which may be at the start of a
      # "virtual" next chunk that doesn't exist yet.
      vcol =
        if vcol == nil and on_cursor_line? and
             cursor_col == chunk_start and chunk_idx == length(chunks) - 1 and
             cursor_col == length(cells) and chunk_idx > 0 do
          0
        else
          vcol
        end

      {chunk, buf_idx, is_first?, vcol}
    end)
    |> maybe_add_cursor_overflow(cells, buf_idx, text_w, on_cursor_line?, cursor_col)
  end

  # When the cursor is at the very end of a line and that position
  # falls exactly on a wrap boundary, we need an extra empty visual
  # row to place the cursor.
  defp maybe_add_cursor_overflow(rows, cells, buf_idx, text_w, true, cursor_col) do
    total_cells = length(cells)

    if cursor_col == total_cells and total_cells > 0 and rem(total_cells, text_w) == 0 do
      # Cursor is at the end and lands exactly on a boundary.
      # Check if any row already has the cursor.
      has_cursor? = Enum.any?(rows, fn {_, _, _, vc} -> vc != nil end)

      if has_cursor? do
        rows
      else
        rows ++ [{[], buf_idx, false, 0}]
      end
    else
      rows
    end
  end

  defp maybe_add_cursor_overflow(rows, _cells, _buf_idx, _text_w, false, _cursor_col), do: rows

  defp ghost_text(%Model{completion: nil}), do: ""
  defp ghost_text(%Model{completion: %Completion{} = c}), do: Completion.ghost_suffix(c)

  defp render_input_row(cells, prompt, on_cursor_row?, cursor_col, ghost) do
    fg = Colors.white()
    prompt_w = String.length(prompt)
    prompt_node = text(prompt, width: prompt_w, fg: fg)

    body =
      if on_cursor_row? do
        col = min(cursor_col, length(cells))
        {before, after_} = Enum.split(cells, col)

        ghost_nodes =
          if ghost == "" do
            []
          else
            [text(ghost, width: String.length(ghost), fg: Colors.dim(), attrs: Attrs.italic())]
          end

        cells_to_nodes(before) ++ [cursor()] ++ ghost_nodes ++ cells_to_nodes(after_)
      else
        cells_to_nodes(cells)
      end

    hbox([height: 1], [prompt_node | body] ++ [fill(flex: 1)])
  end

  # Render a cell list as a flat list of OpenTUI text leaves.
  # Adjacent grapheme cells are coalesced into a single leaf so
  # the renderer has fewer spans to paint; non-rune cells (like a
  # `%Paste{}` chip) produce one or more styled leaves.
  defp cells_to_nodes(cells) do
    cells
    |> chunk_cells()
    |> Enum.flat_map(&chunk_to_nodes/1)
  end

  defp chunk_cells([]), do: []

  defp chunk_cells([cell | _] = cells) when is_binary(cell) do
    {graphemes, rest} = Enum.split_while(cells, &is_binary/1)
    [{:text, Enum.join(graphemes)} | chunk_cells(rest)]
  end

  defp chunk_cells([%Paste{} = p | rest]), do: [{:paste, p} | chunk_cells(rest)]
  defp chunk_cells([%Token{} = t | rest]), do: [{:mention, t} | chunk_cells(rest)]

  defp chunk_to_nodes({:text, str}) do
    [text(str, width: String.length(str), fg: Colors.white())]
  end

  # A paste chip renders as one or two adjacent text leaves on a
  # tinted bg: the head segment in accent fg, plus an optional
  # italic + dim tail segment for `+N lines`. Leaf widths use
  # `display_width/1` so the 📋 emoji (which is one grapheme but
  # two terminal columns wide) doesn't under-fill the bg.
  defp chunk_to_nodes({:paste, %Paste{} = p}) do
    head = Paste.head_segment(p)

    head_node =
      text(head,
        width: display_width(head),
        fg: Colors.accent(),
        bg: Colors.selected_bg()
      )

    case Paste.tail_segment(p) do
      nil ->
        [head_node]

      tail ->
        tail_node =
          text(tail,
            width: display_width(tail),
            fg: Colors.dim(),
            bg: Colors.selected_bg(),
            attrs: Attrs.italic()
          )

        [head_node, tail_node]
    end
  end

  # A mention token renders as a single bold leaf. Agent mentions
  # use the accent colour; record mentions use cyan to echo the
  # wikilink convention. The tinted background matches paste chips
  # so all atomic cells share a visual language.
  defp chunk_to_nodes({:mention, %Token{display: display}}) do
    [
      text(display,
        width: display_width(display),
        fg: Colors.white(),
        attrs: Attrs.bold()
      )
    ]
  end

  # Display columns occupied by a string in a monospace terminal.
  # Most graphemes are 1 cell, but emoji and CJK are 2. We treat
  # any grapheme outside the basic Latin range as wide; that's a
  # rough approximation but it's correct for the chip's 📋 marker
  # and good enough for chat input where the only wide characters
  # we expect are the chip glyph itself.
  defp display_width(str) when is_binary(str) do
    str
    |> String.graphemes()
    |> Enum.reduce(0, fn g, acc -> acc + grapheme_width(g) end)
  end

  defp grapheme_width(<<b, _::binary>>) when b < 128, do: 1
  defp grapheme_width(_), do: 2

  # ---- status --------------------------------------------------------------

  defp status_bar(%Model{status_message: nil}, width) do
    label = " CHAT │ ⏎ send │ /cmd │ ^p/^n scroll │ F1 records │ ^q quit "
    text(pad_to(label, width), height: 1, fg: Colors.white(), bg: Colors.selected_bg())
  end

  defp status_bar(%Model{status_message: msg, status_kind: :warning}, width) do
    label = " #{msg} "
    text(pad_to(label, width), height: 1, fg: Colors.bg(), bg: Colors.warning())
  end

  defp status_bar(%Model{status_message: msg}, width) do
    label = " #{msg} "
    text(pad_to(label, width), height: 1, fg: Colors.fg(), bg: Colors.bg_alt())
  end

  # ---- helpers -------------------------------------------------------------

  defp pad_to(line, width) do
    len = String.length(line)

    cond do
      len >= width -> String.slice(line, 0, width)
      true -> line <> String.duplicate(" ", width - len)
    end
  end

  # Deterministic-by-name agent colour rotation: hash the agent
  # display name into a small palette so the same agent gets the
  # same colour across the session.
  @agent_palette [
    :green,
    :blue,
    :cyan,
    :magenta,
    :yellow,
    :red
  ]

  defp agent_color(name) do
    idx = :erlang.phash2(name, length(@agent_palette))

    case Enum.at(@agent_palette, idx) do
      :green -> Colors.green()
      :blue -> Colors.blue()
      :cyan -> Colors.cyan()
      :magenta -> Colors.magenta()
      :yellow -> Colors.yellow()
      :red -> Colors.red()
    end
  end
end
