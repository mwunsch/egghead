defmodule Egghead.TUI.Chat.View do
  @moduledoc """
  Pure view function for the chat screen.

  Layout (Phase 6c — sidebar lands in 6g):

      ┌───────────────────────────────────┐
      │ egghead · #room · N agents        │  header (1 row)
      ├───────────────────────────────────┤
      │ user: hi                          │
      │ scout: hello                      │  transcript region
      │ scout:▌                           │  (live ghost bubble at bottom)
      │                                   │
      ├───────────────────────────────────┤
      │ ❯ what about activation?▌         │  input row (1 row)
      ├───────────────────────────────────┤
      │ CHAT │ ⏎ send │ esc records │ ^q  │  status bar (1 row)
      └───────────────────────────────────┘

  The transcript region soft-wraps long entry lines on
  whitespace. We always show the *tail* of the rendered lines
  (newest at the bottom), padding with blank space if there
  isn't enough content to fill the region.
  """

  import Egghead.OpenTUI.View

  alias Egghead.OpenTUI.{Attrs, Colors, EditBuffer}
  alias Egghead.TUI.Chat.{Entry, Mentions, Mentions.Token, Model, Paste, Stream}

  @prompt "❯ "
  @continuation "  "
  @max_input_rows 8

  @spec render(Model.t()) :: Egghead.OpenTUI.View.tree()
  def render(%Model{} = model) do
    width = model.width
    height = model.height

    input_height = clamp(EditBuffer.line_count(model.input), 1, @max_input_rows)
    dropdown_height = mention_dropdown_height(model)
    transcript_height = max(height - 2 - input_height - dropdown_height, 1)

    children =
      [header(model, width), transcript_region(model, width, transcript_height),
       input_box(model, width, input_height)] ++
        mention_dropdown_node(model, width, dropdown_height) ++
        [status_bar(model, width)]

    vbox(children)
  end

  @max_dropdown_rows 6

  defp mention_dropdown_height(%Model{mention: %Mentions.Context{candidates: [_ | _] = cs}}),
    do: min(length(cs), @max_dropdown_rows)

  defp mention_dropdown_height(_), do: 0

  defp mention_dropdown_node(%Model{} = model, width, h) when h > 0 do
    [mention_dropdown(model, width, h)]
  end

  defp mention_dropdown_node(_, _, _), do: []

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  # ---- header --------------------------------------------------------------

  defp header(model, width) do
    label =
      " egghead · ##{model.room_id || "—"} · #{length(model.agents)} agents · #{length(model.transcript)} msgs "

    line = pad_to(label, width)

    text(line, height: 1, fg: Colors.white(), bg: Colors.selected_bg())
  end

  # ---- transcript ----------------------------------------------------------

  defp transcript_region(%Model{} = model, width, height) do
    lines = render_transcript_lines(model, width)
    visible = take_tail(lines, height)
    padded = pad_top(visible, height)

    vbox([height: height], Enum.map(padded, &line_to_node/1))
  end

  defp render_transcript_lines(%Model{} = model, width) do
    transcript_lines =
      model.transcript
      |> Enum.flat_map(fn entry -> entry_to_lines(entry, width) end)

    stream_lines =
      model.streams
      |> Map.values()
      |> Enum.sort_by(& &1.started_at)
      |> Enum.flat_map(fn stream -> stream_to_lines(stream, width) end)

    transcript_lines ++ stream_lines
  end

  defp entry_to_lines(%Entry{kind: :user, sender_name: name, text: text}, width) do
    wrap_speaker_lines("#{name}: ", text, width, Colors.cyan())
  end

  defp entry_to_lines(%Entry{kind: :agent, sender_name: name, text: text}, width) do
    wrap_speaker_lines("#{name}: ", text, width, agent_color(name))
  end

  defp entry_to_lines(%Entry{kind: :action, sender_name: name, text: text}, width) do
    wrap_speaker_lines("* #{name} ", text, width, Colors.muted())
  end

  defp entry_to_lines(%Entry{kind: :system, text: text}, width) do
    wrap_speaker_lines("— ", text, width, Colors.muted())
  end

  defp entry_to_lines(%Entry{kind: :handoff, text: text}, width) do
    wrap_speaker_lines("» ", text, width, Colors.accent())
  end

  defp stream_to_lines(%Stream{name: name, current: ""}, width) do
    # Activated but nothing yet — render an ellipsis ghost row.
    wrap_speaker_lines("#{name}: ", "…", width, Colors.muted())
  end

  defp stream_to_lines(%Stream{name: name, current: current}, width) do
    # Append a cursor block to the last line so the ghost bubble
    # looks alive. Soft newlines inside `current` are preserved.
    text = current <> "▌"
    wrap_speaker_lines("#{name}: ", text, width, agent_color(name))
  end

  # Soft-wrap an entry's text body under a speaker prefix. The
  # first wrapped line carries the prefix; continuation lines are
  # indented to the prefix width.
  defp wrap_speaker_lines(prefix, text, width, color) do
    indent_width = String.length(prefix)
    body_width = max(width - indent_width, 1)
    indent = String.duplicate(" ", indent_width)

    text
    |> String.split("\n")
    |> Enum.flat_map(fn paragraph -> soft_wrap(paragraph, body_width) end)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, idx} ->
      lead = if idx == 0, do: prefix, else: indent
      {lead <> chunk, color}
    end)
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

  defp line_to_node({line, color}) do
    text(line, height: 1, fg: color)
  end

  defp take_tail(list, n) do
    len = length(list)

    if len <= n do
      list
    else
      Enum.drop(list, len - n)
    end
  end

  defp pad_top(lines, height) do
    pad = height - length(lines)

    if pad > 0 do
      List.duplicate({"", Colors.dim()}, pad) ++ lines
    else
      lines
    end
  end

  # ---- mention dropdown ----------------------------------------------------

  # Vertical autocomplete list anchored above the input row, much
  # like Claude Code's @-mention picker. Renders up to
  # `@max_dropdown_rows` candidates with the selected one in
  # reverse-video. Up/Down navigate; Enter or Tab accepts; Escape
  # dismisses (handled in Update).
  defp mention_dropdown(%Model{mention: %Mentions.Context{} = ctx}, width, h) do
    sigil =
      case ctx.kind do
        :agent -> "@"
        :record -> "[["
      end

    rows =
      ctx.candidates
      |> Enum.take(h)
      |> Enum.with_index()
      |> Enum.map(fn {cand, idx} ->
        mention_dropdown_row(sigil, cand, ctx.kind, idx == ctx.selected, width)
      end)

    vbox([height: h], rows)
  end

  defp mention_dropdown_row(sigil, candidate, kind, selected?, width) do
    label = mention_label(kind, candidate)
    line = "  #{sigil}#{label}"
    pad = max(width - String.length(line), 0)
    padded = line <> String.duplicate(" ", pad)

    if selected? do
      text(truncate_line(padded, width),
        height: 1,
        fg: Colors.white(),
        bg: Colors.selected_bg()
      )
    else
      text(truncate_line(padded, width),
        height: 1,
        fg: Colors.accent(),
        bg: Colors.bg()
      )
    end
  end

  defp mention_label(:agent, %{id: id}), do: id
  defp mention_label(:agent, %{"id" => id}), do: id
  defp mention_label(:record, %{id: id}), do: id
  defp mention_label(:record, %{"id" => id}), do: id

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
  defp input_box(%Model{input: buffer} = model, _width, input_height) do
    {cursor_row, cursor_col} = EditBuffer.cursor(buffer)
    lines = buffer.lines
    total = length(lines)

    # If the buffer has more lines than the cap, scroll so the
    # cursor row stays visible. Pin to the bottom by default; only
    # shift up when the cursor leaves the window.
    visible_top =
      cond do
        total <= input_height -> 0
        cursor_row >= total - input_height -> total - input_height
        cursor_row < input_height -> 0
        true -> cursor_row - input_height + 1
      end

    visible_lines =
      lines
      |> Enum.drop(visible_top)
      |> Enum.take(input_height)

    ghost = ghost_text(model)

    rows =
      visible_lines
      |> Enum.with_index(visible_top)
      |> Enum.map(fn {cells, idx} ->
        prompt = if idx == 0, do: @prompt, else: @continuation
        on_cursor? = idx == cursor_row
        render_input_row(cells, prompt, on_cursor?, cursor_col, if(on_cursor?, do: ghost, else: ""))
      end)

    vbox([height: input_height], rows)
  end

  defp ghost_text(%Model{mention: nil}), do: ""
  defp ghost_text(%Model{mention: %Mentions.Context{} = ctx}), do: Mentions.ghost_suffix(ctx)

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
    label = " CHAT │ ⏎ send │ esc records │ ^q quit "
    text(pad_to(label, width), height: 1, fg: Colors.white(), bg: Colors.selected_bg())
  end

  defp status_bar(%Model{status_message: msg}, width) do
    label = " ! #{msg} "
    text(pad_to(label, width), height: 1, fg: Colors.white(), bg: Colors.red())
  end

  # ---- helpers -------------------------------------------------------------

  defp pad_to(line, width) do
    len = String.length(line)

    cond do
      len >= width -> String.slice(line, 0, width)
      true -> line <> String.duplicate(" ", width - len)
    end
  end

  # Deterministic-by-name agent colour rotation. Mirrors the
  # convention on `main` of hashing the agent display name into
  # a small palette so the same agent gets the same colour
  # across the session.
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
