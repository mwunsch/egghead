defmodule Egghead.TUI.OrgRender do
  @moduledoc """
  Render an org-mode body to the same row/span shape that
  `Egghead.OpenTUI.Markdown.render/3` produces, so any TUI screen that
  consumes its output (records preview, chat transcript) can display org
  records without a separate wiring path.

  This module lives in the application layer (`Egghead.TUI.*`) rather
  than the framework layer (`Egghead.OpenTUI.*`) because it depends on
  `Egghead.Record.OrgParser`, which the framework must not reference.

  ## Why a dedicated renderer instead of "convert to markdown"

  Org documents carry structure that markdown has no equivalent for —
  TODO/DONE keywords, priorities, headline tags, property drawers,
  `#+`-keywords, active vs. inactive timestamps, source-block markers.
  Converting through Earmark would erase those artifacts and give org
  users a generic view of their own files.

  This renderer preserves them visibly: `*` stars stay on headlines,
  TODO is colored as a keyword, drawers are dimmed but visible, source
  blocks keep their `#+BEGIN_SRC`/`#+END_SRC` lines. The point is that
  what's on disk is what shows in the preview.

  Output type matches `Egghead.OpenTUI.Markdown.rendered/0` exactly.
  """

  alias Egghead.OpenTUI.{Attrs, Colors, Markdown}
  alias Egghead.Record.OrgParser

  @default_max_width 100

  @type rendered :: Markdown.rendered()

  @doc """
  Built-in theme. Apps can `Map.merge(default_theme(), overrides)` for
  partial overrides.
  """
  @spec default_theme() :: Markdown.theme()
  def default_theme do
    %{
      h1: %{fg: Colors.heading(), attrs: Attrs.bold()},
      h2: %{fg: Colors.heading(), attrs: Attrs.bold()},
      h3: %{fg: Colors.heading(), attrs: Attrs.bold()},
      h4: %{fg: Colors.heading(), attrs: Attrs.bold()},
      h5: %{fg: Colors.heading(), attrs: Attrs.bold()},
      h6: %{fg: Colors.heading(), attrs: Attrs.bold()},
      stars: %{fg: Colors.muted(), attrs: 0},
      keyword: %{fg: Colors.muted(), attrs: 0},
      keyword_value: %{fg: :inherit, attrs: 0},
      todo: %{fg: Colors.link(), attrs: Attrs.bold()},
      done: %{fg: Colors.muted(), attrs: Attrs.bold()},
      priority: %{fg: Colors.link(), attrs: Attrs.bold()},
      tag: %{fg: Colors.muted(), attrs: 0},
      drawer: %{fg: Colors.muted(), attrs: 0},
      property_key: %{fg: Colors.muted(), attrs: 0},
      property_value: %{fg: :inherit, attrs: 0},
      block_marker: %{fg: Colors.muted(), attrs: 0},
      code_block: %{fg: Colors.code(), attrs: 0},
      code_inline: %{fg: Colors.code(), attrs: 0},
      verbatim: %{fg: Colors.code(), attrs: 0},
      bold: %{fg: :inherit, attrs: Attrs.bold()},
      italic: %{fg: :inherit, attrs: Attrs.italic()},
      underline: %{fg: :inherit, attrs: Attrs.bold()},
      strikethrough: %{fg: Colors.muted(), attrs: Attrs.strikethrough()},
      link: %{fg: Colors.link(), attrs: 0},
      wikilink: %{fg: Colors.link(), attrs: 0},
      timestamp_active: %{fg: Colors.link(), attrs: 0},
      timestamp_inactive: %{fg: Colors.muted(), attrs: 0},
      list_marker: %{fg: :inherit, attrs: 0}
    }
  end

  @doc """
  Render org body content to a list of styled rows.

  Options:

    * `:theme` — override the default theme. Missing keys fall back.
    * `:max_width` — soft-wrap clamp (default 100).
  """
  @spec render(String.t(), pos_integer(), keyword()) :: rendered()
  def render(body, width, opts \\ [])

  def render(body, width, opts) when is_binary(body) and width > 0 do
    theme = Map.merge(default_theme(), Keyword.get(opts, :theme, %{}))
    max_w = Keyword.get(opts, :max_width, @default_max_width)
    eff_width = min(width, max_w)

    case OrgParser.parse(body) do
      {:ok, ast} ->
        Enum.flat_map(ast, &render_block(&1, eff_width, theme))

      _ ->
        fallback(body)
    end
  rescue
    _ -> fallback(body)
  end

  defp fallback(body) do
    body
    |> String.split("\n")
    |> Enum.map(fn line -> [Markdown.plain_span(line)] end)
  end

  # --- Block rendering ---

  defp render_block({:headline, meta, _children}, width, theme) do
    %{level: level, title: title, keyword: keyword, priority: priority, tags: tags} = meta
    head_key = String.to_atom("h#{min(level, 6)}")
    head_ctx = Markdown.apply_style(Markdown.default_ctx(), theme[head_key])
    star_ctx = Markdown.apply_style(Markdown.default_ctx(), theme[:stars])

    stars = String.duplicate("*", level)

    parts =
      [Markdown.plain_span(stars <> " ", star_ctx)]
      |> maybe_append_keyword(keyword, theme)
      |> maybe_append_priority(priority, theme)
      |> Kernel.++([Markdown.plain_span(title, head_ctx)])
      |> maybe_append_tags(tags, theme)

    Markdown.wrap_spans(parts, width) ++ [[]]
  end

  defp render_block({:keyword, %{key: key, value: value}, _}, width, theme) do
    kw_ctx = Markdown.apply_style(Markdown.default_ctx(), theme[:keyword])
    val_ctx = Markdown.apply_style(Markdown.default_ctx(), theme[:keyword_value])

    spans = [
      Markdown.plain_span("#+#{key}: ", kw_ctx),
      Markdown.plain_span(value, val_ctx)
    ]

    Markdown.wrap_spans(spans, width)
  end

  defp render_block({:property_drawer, _, props}, _width, theme) do
    drawer_ctx = Markdown.apply_style(Markdown.default_ctx(), theme[:drawer])
    key_ctx = Markdown.apply_style(Markdown.default_ctx(), theme[:property_key])
    val_ctx = Markdown.apply_style(Markdown.default_ctx(), theme[:property_value])

    open_row = [Markdown.plain_span(":PROPERTIES:", drawer_ctx)]
    close_row = [Markdown.plain_span(":END:", drawer_ctx)]

    rows =
      Enum.map(props, fn {k, v} ->
        [
          Markdown.plain_span(":#{k}: ", key_ctx),
          Markdown.plain_span(v, val_ctx)
        ]
      end)

    [open_row | rows] ++ [close_row, []]
  end

  defp render_block({:src_block, %{language: lang}, content}, width, theme) do
    marker_ctx = Markdown.apply_style(Markdown.default_ctx(), theme[:block_marker])
    code_ctx = Markdown.apply_style(Markdown.default_ctx(), theme[:code_block])
    label = if lang, do: " " <> lang, else: ""

    code_lines =
      content
      |> String.split("\n")
      |> Enum.map(fn line ->
        truncated = String.slice(line, 0, max(1, width - 2))
        [Markdown.plain_span("  " <> truncated, code_ctx)]
      end)

    [[Markdown.plain_span("#+BEGIN_SRC" <> label, marker_ctx)]] ++
      code_lines ++
      [[Markdown.plain_span("#+END_SRC", marker_ctx)], []]
  end

  defp render_block({:example_block, _, content}, width, theme) do
    marker_ctx = Markdown.apply_style(Markdown.default_ctx(), theme[:block_marker])
    code_ctx = Markdown.apply_style(Markdown.default_ctx(), theme[:code_block])

    lines =
      content
      |> String.split("\n")
      |> Enum.map(fn line ->
        truncated = String.slice(line, 0, max(1, width - 2))
        [Markdown.plain_span("  " <> truncated, code_ctx)]
      end)

    [[Markdown.plain_span("#+BEGIN_EXAMPLE", marker_ctx)]] ++
      lines ++
      [[Markdown.plain_span("#+END_EXAMPLE", marker_ctx)], []]
  end

  defp render_block({:quote_block, _, inner}, width, theme) do
    inner_width = max(1, width - 2)
    quote_ctx = Markdown.apply_style(Markdown.default_ctx(), theme[:drawer])

    inner
    |> Enum.flat_map(&render_block(&1, inner_width, theme))
    |> Enum.map(fn
      [] -> [Markdown.plain_span("  │", quote_ctx)]
      row -> [Markdown.plain_span("  │ ", quote_ctx) | row]
    end)
  end

  defp render_block({:plain_list, _, items}, width, theme) do
    rows =
      Enum.flat_map(items, fn item -> render_list_item(item, width, theme) end)

    rows ++ [[]]
  end

  defp render_block({:paragraph, _, inline}, width, theme) do
    spans = render_inline(inline, Markdown.default_ctx(), theme)
    Markdown.wrap_spans(spans, width) ++ [[]]
  end

  defp render_block(text, width, _theme) when is_binary(text) do
    Markdown.wrap_spans([Markdown.plain_span(text)], width)
  end

  defp render_block(_, _, _), do: []

  # --- List items ---

  defp render_list_item({:list_item, %{checkbox: checkbox, bullet: bullet}, inline}, width, theme) do
    marker_ctx = Markdown.apply_style(Markdown.default_ctx(), theme[:list_marker])

    marker =
      case checkbox do
        :checked -> "☑ "
        :partial -> "☐ "
        :unchecked -> "☐ "
        _ -> bullet_marker(bullet)
      end

    prefix = "  " <> marker
    indent_w = String.length(prefix)
    inner_width = max(1, width - indent_w)
    indent = String.duplicate(" ", indent_w)
    spans = render_inline(inline, Markdown.default_ctx(), theme)
    rows = Markdown.wrap_spans(spans, inner_width)

    case rows do
      [] ->
        [[Markdown.plain_span(prefix, marker_ctx)]]

      [first | rest] ->
        [
          [Markdown.plain_span(prefix, marker_ctx) | first]
          | Enum.map(rest, fn row -> [Markdown.plain_span(indent, marker_ctx) | row] end)
        ]
    end
  end

  defp render_list_item(_, _, _), do: []

  defp bullet_marker(b) when is_binary(b) do
    cond do
      String.match?(b, ~r/^\d+[.)]/) -> b <> " "
      true -> "· "
    end
  end

  defp bullet_marker(_), do: "· "

  # --- Inline elements ---

  defp render_inline(elements, ctx, theme) when is_list(elements) do
    Enum.flat_map(elements, &render_inline_one(&1, ctx, theme))
  end

  defp render_inline_one({:text, text}, ctx, _theme),
    do: [Markdown.plain_span(normalize_inline_text(text), ctx)]

  defp render_inline_one({:bold, text}, ctx, theme) do
    styled = Markdown.apply_style(ctx, theme[:bold])
    [Markdown.plain_span("*" <> text <> "*", styled)]
  end

  defp render_inline_one({:italic, text}, ctx, theme) do
    styled = Markdown.apply_style(ctx, theme[:italic])
    [Markdown.plain_span("/" <> text <> "/", styled)]
  end

  defp render_inline_one({:code, text}, ctx, theme) do
    styled = Markdown.apply_style(ctx, theme[:code_inline])
    [Markdown.plain_span("~" <> text <> "~", styled)]
  end

  defp render_inline_one({:verbatim, text}, ctx, theme) do
    styled = Markdown.apply_style(ctx, theme[:verbatim])
    [Markdown.plain_span("=" <> text <> "=", styled)]
  end

  defp render_inline_one({:underline, text}, ctx, theme) do
    styled = Markdown.apply_style(ctx, theme[:underline])
    [Markdown.plain_span("_" <> text <> "_", styled)]
  end

  defp render_inline_one({:strikethrough, text}, ctx, theme) do
    styled = Markdown.apply_style(ctx, theme[:strikethrough])
    [Markdown.plain_span("+" <> text <> "+", styled)]
  end

  defp render_inline_one({:link, %{target: target, display: display}}, ctx, theme) do
    text =
      if display in [nil, ""] do
        "[[#{target}]]"
      else
        "[[#{target}][#{display}]]"
      end

    style_key = if external?(target), do: :link, else: :wikilink
    styled = Markdown.apply_style(ctx, theme[style_key])

    span = Markdown.plain_span(text, styled)

    span =
      if style_key == :wikilink,
        do: %{span | link: {:wikilink, strip_fragment(target)}},
        else: span

    [span]
  end

  defp render_inline_one(
         {:timestamp, %{type: type, date: date, day: day, time: time}},
         ctx,
         theme
       ) do
    {open, close} = if type == :active, do: {"<", ">"}, else: {"[", "]"}

    body =
      [date, day, time]
      |> Enum.reject(&(&1 == nil or &1 == ""))
      |> Enum.join(" ")

    style_key = if type == :active, do: :timestamp_active, else: :timestamp_inactive
    styled = Markdown.apply_style(ctx, theme[style_key])
    [Markdown.plain_span(open <> body <> close, styled)]
  end

  defp render_inline_one(text, ctx, _theme) when is_binary(text),
    do: [Markdown.plain_span(text, ctx)]

  defp render_inline_one(_, _ctx, _theme), do: []

  # --- Helpers ---

  defp maybe_append_keyword(parts, nil, _theme), do: parts

  defp maybe_append_keyword(parts, keyword, theme) do
    style_key = if String.upcase(keyword) == "DONE", do: :done, else: :todo
    styled = Markdown.apply_style(Markdown.default_ctx(), theme[style_key])
    parts ++ [Markdown.plain_span(keyword <> " ", styled)]
  end

  defp maybe_append_priority(parts, nil, _theme), do: parts

  defp maybe_append_priority(parts, priority, theme) do
    styled = Markdown.apply_style(Markdown.default_ctx(), theme[:priority])
    parts ++ [Markdown.plain_span("[#" <> priority <> "] ", styled)]
  end

  defp maybe_append_tags(parts, [], _theme), do: parts

  defp maybe_append_tags(parts, tags, theme) when is_list(tags) do
    styled = Markdown.apply_style(Markdown.default_ctx(), theme[:tag])
    text = " :" <> Enum.join(tags, ":") <> ":"
    parts ++ [Markdown.plain_span(text, styled)]
  end

  defp external?(target) do
    String.contains?(target, "://") or
      String.starts_with?(target, "/") or
      String.starts_with?(target, "mailto:") or
      String.starts_with?(target, "file:")
  end

  defp strip_fragment(target) do
    case String.split(target, "#", parts: 2) do
      [t, _] -> t
      [t] -> t
    end
  end

  # Inline text inside a paragraph is single-logical-line. If a stray
  # `\n` slipped through (e.g. from a multi-line block that fell back
  # to a literal-text span), turn it into a space so the row renders
  # without word concatenation. Word-wrap is wrap_spans' job, not
  # the text content's.
  defp normalize_inline_text(text) when is_binary(text), do: String.replace(text, "\n", " ")
end
