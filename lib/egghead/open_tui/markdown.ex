defmodule Egghead.OpenTUI.Markdown do
  @moduledoc """
  Render markdown to a list of styled rows for any OpenTUI screen.

  Any view that wants to display formatted prose can render
  through this module — the output is plain data (rows of
  styled spans) and composes directly with the view tree.

  ## Output

  Each row is a list of spans:

      @type span :: %{
              text: String.t(),
              fg: binary() | nil,
              attrs: non_neg_integer(),
              link: nil | {:wikilink, String.t()}
            }
      @type row :: [span]
      @type rendered :: [row]

  Spans preserve inline markup at the token level: bold/italic/
  code/strike spans carry the OpenTUI attribute bits, wikilink
  spans carry their target so the host screen can highlight the
  active link in place. Word wrap is span-aware — wrapping a
  paragraph of mixed inline styles preserves the styles within
  each output line.

  Soft-wrap clamps to `min(width, max_content_width)` so reading
  line length stays sane on wide terminals. The pane stays
  full-width for chrome; only the rendered text clamps. Default
  is 100 columns; override via `:max_width` opt.

  ## Theming

  Every styled element looks up its style from a `theme` map.
  The default theme uses `Egghead.OpenTUI.Colors`; pass a custom
  theme to swap palette or attributes per call:

      Markdown.render(body, width, theme: my_theme)

  Theme entries are `%{fg: binary | :inherit, attrs: bits}`.
  Block styles (h1, code_block, blockquote) replace the
  inherited fg; inline styles (bold, italic, strikethrough)
  with `fg: :inherit` keep the parent fg and only OR their
  attribute bits. Apps can build a partial theme — missing keys
  fall back to `default_theme/0`.

  ## Strikethrough

  Earmark generates `<del>` nodes for `~~text~~` under default
  options. We map them to the `STRIKETHROUGH` attribute bit (and
  the muted color, so it's still legible on terminals that don't
  render the SGR).

  ## Wikilink discovery

  Use `find_wikilink_row/2` to locate the row index where a
  given wikilink target appears. Callers can walk the spans of
  that row to highlight the active link in place.
  """

  alias Egghead.OpenTUI.{Attrs, Colors}

  @default_max_width 100

  # gfm: true is the default in Earmark; pure_links: true is too.
  # We add wikilinks for `[[target]]` parsing, gfm_tables for the
  # `|` table form, footnotes for `[^id]` refs, and sub_sup for
  # `~sub~` / `^sup^`.
  @earmark_opts [wikilinks: true, gfm_tables: true, footnotes: true, sub_sup: true]

  @type style :: %{
          required(:fg) => binary() | :inherit,
          required(:attrs) => non_neg_integer()
        }

  @type theme :: %{optional(atom()) => style()}

  @type span :: %{
          required(:text) => String.t(),
          required(:fg) => binary() | nil,
          required(:attrs) => non_neg_integer(),
          required(:link) => nil | {:wikilink, String.t()}
        }
  @type row :: [span()]
  @type rendered :: [row()]

  @doc """
  Built-in theme. Apps can `Map.merge(default_theme(), overrides)`
  to override individual keys.

  Block styles (h1, h2, h3, code_block, blockquote, hr) set both
  fg and attrs. Inline modifiers (bold, italic, strikethrough)
  use `fg: :inherit` so they compose with surrounding context.
  """
  @spec default_theme() :: theme()
  def default_theme do
    %{
      # Block styles
      h1: %{fg: Colors.heading(), attrs: Attrs.bold()},
      h2: %{fg: Colors.heading(), attrs: Attrs.bold()},
      h3: %{fg: Colors.heading(), attrs: Attrs.bold()},
      h4: %{fg: Colors.heading(), attrs: Attrs.bold()},
      h5: %{fg: Colors.heading(), attrs: Attrs.bold()},
      h6: %{fg: Colors.heading(), attrs: Attrs.bold()},
      code_block: %{fg: Colors.code(), attrs: 0},
      blockquote: %{fg: Colors.muted(), attrs: 0},
      hr: %{fg: Colors.muted(), attrs: 0},
      list_marker: %{fg: :inherit, attrs: 0},
      task_done: %{fg: Colors.muted(), attrs: 0},
      task_todo: %{fg: :inherit, attrs: 0},

      # Inline modifiers (fg: :inherit)
      bold: %{fg: :inherit, attrs: Attrs.bold()},
      italic: %{fg: :inherit, attrs: Attrs.italic()},
      strikethrough: %{fg: Colors.muted(), attrs: Attrs.strikethrough()},

      # Inline elements with their own color
      code_inline: %{fg: Colors.code(), attrs: 0},
      link: %{fg: Colors.link(), attrs: 0},
      wikilink: %{fg: Colors.link(), attrs: 0},
      footnote_ref: %{fg: Colors.muted(), attrs: 0},

      # Tables
      table_border: %{fg: Colors.muted(), attrs: 0},
      table_header: %{fg: Colors.heading(), attrs: Attrs.bold()},
      table_cell: %{fg: :inherit, attrs: 0},

      # Footnotes section
      footnote_body: %{fg: Colors.muted(), attrs: 0},
      footnote_separator: %{fg: Colors.muted(), attrs: 0}
    }
  end

  @doc """
  Render `markdown` to a list of styled rows.

  Options:

    * `:theme` — override the default theme. Missing keys fall
      back to `default_theme/0`.
    * `:max_width` — override the soft-wrap clamp (default 100).
  """
  @spec render(String.t(), pos_integer(), keyword()) :: rendered()
  def render(markdown, width, opts \\ [])

  def render(markdown, width, opts) when is_binary(markdown) and width > 0 do
    theme = build_theme(Keyword.get(opts, :theme, %{}))
    max_w = Keyword.get(opts, :max_width, @default_max_width)
    eff_width = min(width, max_w)

    case Earmark.as_ast(markdown, @earmark_opts) do
      {:ok, ast, _} when is_list(ast) ->
        Enum.flat_map(ast, &render_node(&1, eff_width, theme))

      _ ->
        fallback(markdown)
    end
  rescue
    _ -> fallback(markdown)
  end

  @doc """
  Find the row index where `target` first appears as a wikilink
  span. Returns `nil` if no row contains a span pointing at the
  target.
  """
  @spec find_wikilink_row(rendered(), String.t()) :: non_neg_integer() | nil
  def find_wikilink_row(rendered, target) when is_binary(target) do
    Enum.find_index(rendered, fn row ->
      Enum.any?(row, fn span -> span.link == {:wikilink, target} end)
    end)
  end

  @doc """
  Effective text width given a raw column count and the same opts
  as `render/3`. Useful when caching: callers can compute the
  width that the renderer actually used.
  """
  @spec effective_width(pos_integer(), keyword()) :: pos_integer()
  def effective_width(width, opts \\ []) when is_integer(width) and width > 0 do
    max_w = Keyword.get(opts, :max_width, @default_max_width)
    min(width, max_w)
  end

  defp build_theme(overrides) when is_map(overrides) do
    Map.merge(default_theme(), overrides)
  end

  defp build_theme(_), do: default_theme()

  defp fallback(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.map(fn line -> [plain_span(line)] end)
  end

  # ---- block-level rendering ---------------------------------------------

  defp render_node({"h1", _, children, _}, width, theme), do: heading(children, "# ", :h1, width, theme)
  defp render_node({"h2", _, children, _}, width, theme), do: heading(children, "## ", :h2, width, theme)
  defp render_node({"h3", _, children, _}, width, theme), do: heading(children, "### ", :h3, width, theme)
  defp render_node({"h4", _, children, _}, width, theme), do: heading(children, "#### ", :h4, width, theme)
  defp render_node({"h5", _, children, _}, width, theme), do: heading(children, "##### ", :h5, width, theme)
  defp render_node({"h6", _, children, _}, width, theme), do: heading(children, "###### ", :h6, width, theme)

  defp render_node({"p", _, children, _}, width, theme) do
    spans = extract_spans(children, default_ctx(), theme)
    wrap_spans(spans, width) ++ [[]]
  end

  defp render_node({"pre", _, [{"code", attrs, [code], _}], _}, width, theme)
       when is_binary(code) do
    lang =
      case List.keyfind(attrs, "class", 0) do
        {"class", l} -> l
        _ -> nil
      end

    code_ctx = apply_style(default_ctx(), theme[:code_block])

    header =
      if lang,
        do: [[plain_span("  ┌─ #{lang} ", code_ctx)]],
        else: []

    code_lines =
      code
      |> String.split("\n")
      |> Enum.map(fn line ->
        truncated = String.slice(line, 0, max(1, width - 6))
        [plain_span("  │ " <> truncated, code_ctx)]
      end)

    header ++ code_lines ++ [[plain_span("  └─", code_ctx)], []]
  end

  defp render_node({"pre", _, children, _}, width, theme) do
    code_ctx = apply_style(default_ctx(), theme[:code_block])

    children
    |> extract_plain_text()
    |> String.split("\n")
    |> Enum.map(fn line ->
      truncated = String.slice(line, 0, max(1, width - 4))
      [plain_span("  " <> truncated, code_ctx)]
    end)
    |> Kernel.++([[]])
  end

  defp render_node({"ul", _, items, _}, width, theme) do
    rows =
      Enum.flat_map(items, fn
        {"li", _, children, _} ->
          plain = extract_plain_text(children)

          case parse_task_marker(plain) do
            {:task, :done, _} ->
              spans =
                children
                |> extract_spans(apply_style(default_ctx(), theme[:task_done]), theme)
                |> strip_task_marker_spans()

              render_li("☑", spans, width, apply_style(default_ctx(), theme[:task_done]))

            {:task, :todo, _} ->
              spans =
                children
                |> extract_spans(apply_style(default_ctx(), theme[:task_todo]), theme)
                |> strip_task_marker_spans()

              render_li("☐", spans, width, apply_style(default_ctx(), theme[:task_todo]))

            :no_task ->
              spans = extract_spans(children, default_ctx(), theme)
              render_li("·", spans, width, apply_style(default_ctx(), theme[:list_marker]))
          end

        _ ->
          []
      end)

    rows ++ [[]]
  end

  defp render_node({"ol", _, items, _}, width, theme) do
    rows =
      items
      |> Enum.with_index(1)
      |> Enum.flat_map(fn
        {{"li", _, children, _}, n} ->
          spans = extract_spans(children, default_ctx(), theme)
          render_li("#{n}.", spans, width, apply_style(default_ctx(), theme[:list_marker]))

        _ ->
          []
      end)

    rows ++ [[]]
  end

  defp render_node({"blockquote", _, children, _}, width, theme) do
    inner_width = max(1, width - 4)
    quote_ctx = apply_style(default_ctx(), theme[:blockquote])

    children
    |> Enum.flat_map(&render_node(&1, inner_width, theme))
    |> Enum.map(fn
      [] -> [plain_span("  │", quote_ctx)]
      row -> [plain_span("  │ ", quote_ctx) | row]
    end)
  end

  defp render_node({"hr", _, _, _}, width, theme) do
    rule = String.duplicate("─", max(1, width - 4))
    [[plain_span("  " <> rule, apply_style(default_ctx(), theme[:hr]))], []]
  end

  defp render_node({"table", _, children, _}, width, theme) do
    Egghead.OpenTUI.Markdown.Table.render(children, width, theme)
  end

  # Footnotes section: <div class="footnotes"><hr/><ol>...</ol></div>
  defp render_node({"div", attrs, children, _}, width, theme) do
    case List.keyfind(attrs, "class", 0) do
      {"class", "footnotes"} -> render_footnotes_section(children, width, theme)
      _ -> Enum.flat_map(children, &render_node(&1, width, theme))
    end
  end

  defp render_node(text, width, _theme) when is_binary(text) do
    wrap_spans([plain_span(text)], width)
  end

  defp render_node({_tag, _, children, _}, width, theme) do
    spans = extract_spans(children, default_ctx(), theme)
    wrap_spans(spans, width) ++ [[]]
  end

  defp render_node(_, _width, _theme), do: []

  defp heading(children, prefix, theme_key, width, theme) do
    style = theme[theme_key]
    ctx = apply_style(default_ctx(), style)
    spans = extract_spans(children, ctx, theme)
    rows = wrap_spans([plain_span(prefix, ctx) | spans], width)
    rows ++ [[]]
  end

  # ---- list-item helpers --------------------------------------------------

  defp parse_task_marker("[ ] " <> rest), do: {:task, :todo, rest}
  defp parse_task_marker("[x] " <> rest), do: {:task, :done, rest}
  defp parse_task_marker("[X] " <> rest), do: {:task, :done, rest}
  defp parse_task_marker(_), do: :no_task

  defp strip_task_marker_spans([%{text: text} = head | rest]) do
    new_text =
      cond do
        String.starts_with?(text, "[ ] ") -> String.slice(text, 4..-1//1)
        String.starts_with?(text, "[x] ") -> String.slice(text, 4..-1//1)
        String.starts_with?(text, "[X] ") -> String.slice(text, 4..-1//1)
        true -> text
      end

    if new_text == "", do: rest, else: [%{head | text: new_text} | rest]
  end

  defp strip_task_marker_spans(spans), do: spans

  defp render_li(marker, spans, width, prefix_ctx) do
    prefix = "  #{marker} "
    indent_w = String.length(prefix)
    inner_width = max(1, width - indent_w)
    indent = String.duplicate(" ", indent_w)

    rows = wrap_spans(spans, inner_width)

    case rows do
      [] ->
        [[plain_span(prefix, prefix_ctx)]]

      [first | rest] ->
        first_row = [plain_span(prefix, prefix_ctx) | first]

        rest_rows =
          Enum.map(rest, fn row ->
            [plain_span(indent, prefix_ctx) | row]
          end)

        [first_row | rest_rows]
    end
  end

  # ---- footnotes ----------------------------------------------------------

  defp render_footnotes_section(children, width, theme) do
    items =
      children
      |> Enum.flat_map(fn
        {"ol", _, lis, _} -> lis
        _ -> []
      end)

    sep_ctx = apply_style(default_ctx(), theme[:footnote_separator])
    body_ctx = apply_style(default_ctx(), theme[:footnote_body])

    header = [
      [],
      [plain_span("── Footnotes ──", sep_ctx)],
      []
    ]

    rendered =
      items
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{"li", attrs, content, _}, n} ->
        # Strip the reversefootnote anchor that Earmark prepends.
        content =
          Enum.reject(content, fn
            {"a", a, _, _} ->
              case List.keyfind(a, "class", 0) do
                {"class", "reversefootnote"} -> true
                _ -> false
              end

            _ ->
              false
          end)

        id =
          case List.keyfind(attrs, "id", 0) do
            {"id", "fn:" <> raw} -> raw
            _ -> "#{n}"
          end

        body_spans =
          content
          |> Enum.flat_map(fn
            {"p", _, kids, _} -> extract_spans(kids, body_ctx, theme)
            other -> extract_spans([other], body_ctx, theme)
          end)

        prefix = "  [#{id}] "
        indent_w = String.length(prefix)
        inner_width = max(1, width - indent_w)
        indent = String.duplicate(" ", indent_w)

        rows = wrap_spans(body_spans, inner_width)

        case rows do
          [] ->
            [[plain_span(prefix, body_ctx)]]

          [first | rest] ->
            [
              [plain_span(prefix, body_ctx) | first]
              | Enum.map(rest, fn row -> [plain_span(indent, body_ctx) | row] end)
            ]
        end
      end)

    header ++ rendered ++ [[]]
  end

  # ---- inline span extraction --------------------------------------------

  @doc false
  def default_ctx, do: %{fg: nil, attrs: 0, link: nil}

  @doc false
  def apply_style(ctx, nil), do: ctx

  def apply_style(ctx, %{fg: :inherit, attrs: a}) do
    %{ctx | attrs: Bitwise.bor(ctx.attrs, a)}
  end

  def apply_style(ctx, %{fg: fg, attrs: a}) do
    %{ctx | fg: fg, attrs: Bitwise.bor(ctx.attrs, a)}
  end

  defp extract_spans(children, ctx, theme) when is_list(children) do
    Enum.flat_map(children, &extract_span_node(&1, ctx, theme))
  end

  defp extract_spans(text, ctx, _theme) when is_binary(text), do: [plain_span(text, ctx)]
  defp extract_spans(_, _ctx, _theme), do: []

  defp extract_span_node(text, ctx, _theme) when is_binary(text) do
    [plain_span(text, ctx)]
  end

  defp extract_span_node({"strong", _, kids, _}, ctx, theme),
    do: extract_spans(kids, apply_style(ctx, theme[:bold]), theme)

  defp extract_span_node({"em", _, kids, _}, ctx, theme),
    do: extract_spans(kids, apply_style(ctx, theme[:italic]), theme)

  defp extract_span_node({"code", _, kids, _}, ctx, theme),
    do: extract_spans(kids, apply_style(ctx, theme[:code_inline]), theme)

  defp extract_span_node({"del", _, kids, _}, ctx, theme),
    do: extract_spans(kids, apply_style(ctx, theme[:strikethrough]), theme)

  defp extract_span_node({"s", _, kids, _}, ctx, theme),
    do: extract_spans(kids, apply_style(ctx, theme[:strikethrough]), theme)

  # Wikilink: render as [[target]] or [[target|display]] and tag
  # the resulting span with the target.
  defp extract_span_node({"a", attrs, kids, %{wikilink: true}}, ctx, theme) do
    target = attrs_get(attrs, "href", "")
    display = extract_plain_text(kids)

    text =
      if display == "" or display == target,
        do: "[[#{target}]]",
        else: "[[#{target}|#{display}]]"

    link_ctx = apply_style(ctx, theme[:wikilink])
    [plain_span(text, %{link_ctx | link: {:wikilink, target}})]
  end

  # Footnote reference: render as ^[id].
  defp extract_span_node({"a", attrs, [id], _meta}, ctx, theme) when is_binary(id) do
    case attrs_get(attrs, "class", "") do
      "footnote" -> [plain_span("^[#{id}]", apply_style(ctx, theme[:footnote_ref]))]
      _ -> [plain_span(id, apply_style(ctx, theme[:link]))]
    end
  end

  defp extract_span_node({"a", _, kids, _}, ctx, theme),
    do: extract_spans(kids, apply_style(ctx, theme[:link]), theme)

  defp extract_span_node({"br", _, _, _}, ctx, _theme),
    do: [%{text: "\n", fg: ctx.fg, attrs: ctx.attrs, link: ctx.link}]

  defp extract_span_node({"sub", _, kids, _}, ctx, theme),
    do: [plain_span("_", ctx) | extract_spans(kids, ctx, theme)]

  defp extract_span_node({"sup", _, kids, _}, ctx, theme),
    do: [plain_span("^", ctx) | extract_spans(kids, ctx, theme)]

  defp extract_span_node({_tag, _, kids, _}, ctx, theme), do: extract_spans(kids, ctx, theme)
  defp extract_span_node(_, _ctx, _theme), do: []

  # Plain-text fallback: just concatenate text content, no styling.
  defp extract_plain_text(children) when is_list(children) do
    Enum.map_join(children, "", fn
      text when is_binary(text) -> text
      {_tag, _attrs, kids, _meta} -> extract_plain_text(kids)
      _ -> ""
    end)
  end

  defp extract_plain_text(text) when is_binary(text), do: text
  defp extract_plain_text(_), do: ""

  defp attrs_get(attrs, key, default) do
    case List.keyfind(attrs, key, 0) do
      {^key, value} -> value
      _ -> default
    end
  end

  # ---- span constructors --------------------------------------------------

  @doc false
  def plain_span(text), do: plain_span(text, default_ctx())

  @doc false
  def plain_span(text, ctx) do
    %{text: text, fg: ctx.fg, attrs: ctx.attrs, link: ctx.link}
  end

  # ---- span-aware word wrap ----------------------------------------------

  # Wrap a list of spans into rows of <= width columns. Hard
  # newlines (from <br> and embedded "\n") force a row break;
  # everything else is greedy-fill at word boundaries.
  defp wrap_spans(spans, width) when width > 0 do
    spans
    |> tokenize()
    |> fill_rows(width)
  end

  defp wrap_spans(_spans, _width), do: [[]]

  # Convert spans to a flat token stream of:
  #   {:word, span}    — non-whitespace run, atomic
  #   {:space, span}   — single space, may be dropped at row edges
  #   :break           — hard line break
  defp tokenize(spans) do
    Enum.flat_map(spans, &tokenize_span/1)
  end

  defp tokenize_span(%{text: text} = span) do
    text
    |> split_by_newlines()
    |> Enum.flat_map(fn
      :break ->
        [:break]

      chunk when is_binary(chunk) ->
        chunk
        |> String.split(~r/\s+/, include_captures: true, trim: false)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn part ->
          if Regex.match?(~r/^\s+$/, part) do
            {:space, %{span | text: " "}}
          else
            {:word, %{span | text: part}}
          end
        end)
    end)
  end

  defp split_by_newlines(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.intersperse(:break)
    |> Enum.reject(&(&1 == ""))
  end

  defp fill_rows(tokens, width) do
    {rows, current, _used} =
      Enum.reduce(tokens, {[], [], 0}, fn
        :break, {rows, current, _used} ->
          {[finalize_row(current) | rows], [], 0}

        {:space, span}, {rows, current, used} ->
          cond do
            current == [] -> {rows, current, used}
            used + 1 > width -> {[finalize_row(current) | rows], [], 0}
            true -> {rows, [span | current], used + 1}
          end

        {:word, span}, {rows, current, used} ->
          word_len = String.length(span.text)

          cond do
            word_len > width ->
              flushed_rows =
                if current == [], do: rows, else: [finalize_row(current) | rows]

              {chunks_rev, leftover} = chunk_word(span, width)
              {chunks_rev ++ flushed_rows, leftover, length_or_zero(leftover)}

            current == [] ->
              {rows, [span], word_len}

            used + word_len > width ->
              {[finalize_row(current) | rows], [span], word_len}

            true ->
              {rows, [span | current], used + word_len}
          end
      end)

    final = if current == [], do: rows, else: [finalize_row(current) | rows]
    Enum.reverse(final)
  end

  defp finalize_row(reversed_spans) do
    reversed_spans
    |> Enum.reverse()
    |> merge_adjacent()
  end

  defp merge_adjacent([]), do: []
  defp merge_adjacent([span]), do: [span]

  defp merge_adjacent([a, b | rest]) do
    if same_style?(a, b) do
      merge_adjacent([%{a | text: a.text <> b.text} | rest])
    else
      [a | merge_adjacent([b | rest])]
    end
  end

  defp same_style?(a, b),
    do: a.fg == b.fg and a.attrs == b.attrs and a.link == b.link

  defp chunk_word(span, width) do
    chars = String.graphemes(span.text)
    do_chunk_word(chars, span, width, [])
  end

  defp do_chunk_word([], _span, _width, acc_rows), do: {acc_rows, []}

  defp do_chunk_word(chars, span, width, acc_rows) do
    if length(chars) <= width do
      {acc_rows, [%{span | text: Enum.join(chars, "")}]}
    else
      {head, tail} = Enum.split(chars, width)
      row = [%{span | text: Enum.join(head, "")}]
      do_chunk_word(tail, span, width, [finalize_row(row) | acc_rows])
    end
  end

  defp length_or_zero([]), do: 0

  defp length_or_zero(spans) do
    spans |> Enum.map(&String.length(&1.text)) |> Enum.sum()
  end
end
