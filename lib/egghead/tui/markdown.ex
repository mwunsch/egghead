defmodule Egghead.TUI.Markdown do
  @moduledoc """
  Renders markdown to styled terminal text lines using Earmark's AST.

  Returns a list of `{text, style}` tuples for the TUI to render.
  """

  alias TermUI.Renderer.Style
  alias Egghead.TUI.Theme

  @doc """
  Renders a markdown string to a list of `{text, style}` tuples,
  one per display line, word-wrapped to `width`.
  """
  # Default style for unstyled text — explicit fg so text is visible.
  # bg is nil → Cell :default → terminal's native background.
  @text_style Style.new(fg: :white)

  # Earmark options enabled:
  # - wikilinks: parses [[target]] / [[target|display]] as marked anchors
  # - gfm_tables: parses pipe tables (| col | col | with --- separator)
  # - footnotes: parses [^id] references and [^id]: definitions
  # - sub_sup: parses ~sub~ and ^sup^ syntax
  # gfm: true is the default; pure_links: true is the default.
  @earmark_opts [wikilinks: true, gfm_tables: true, footnotes: true, sub_sup: true]

  @spec render(String.t(), pos_integer()) :: [{String.t(), Style.t()}]
  def render(markdown, width) when is_binary(markdown) and width > 0 do
    lines =
      case Earmark.as_ast!(markdown, @earmark_opts) do
        ast when is_list(ast) ->
          Enum.flat_map(ast, &render_node(&1, width))

        _ ->
          markdown |> String.split("\n") |> Enum.map(&{&1, @text_style})
      end

    # Ensure no nil styles — replace with default text style
    Enum.map(lines, fn
      {text, nil} -> {text, @text_style}
      line -> line
    end)
  rescue
    _ ->
      markdown |> String.split("\n") |> Enum.map(&{&1, @text_style})
  end

  @doc """
  Find the line index where a given wikilink target appears in rendered lines.

  Searches for `[[target]]` or `[[target|...]]` literally in each line.
  Returns the first matching line index, or nil if not found.
  """
  @spec find_wikilink_line([{String.t(), Style.t()}], String.t()) :: integer() | nil
  def find_wikilink_line(lines, target) when is_binary(target) do
    pattern_exact = "[[#{target}]]"
    pattern_pipe = "[[#{target}|"

    Enum.find_index(lines, fn {text, _style} ->
      String.contains?(text, pattern_exact) or String.contains?(text, pattern_pipe)
    end)
  end

  def find_wikilink_line(_, _), do: nil

  # --- AST node rendering ---

  defp render_node({"h1", _, children, _}, _width) do
    text = "# " <> extract_text(children)
    [{text, Theme.md_h1()}, {"", nil}]
  end

  defp render_node({"h2", _, children, _}, _width) do
    text = "## " <> extract_text(children)
    [{text, Theme.md_h2()}, {"", nil}]
  end

  defp render_node({"h3", _, children, _}, _width) do
    text = "### " <> extract_text(children)
    [{text, Theme.md_h3()}, {"", nil}]
  end

  defp render_node({"h" <> _, _, children, _}, _width) do
    text = extract_text(children)
    [{text, Theme.md_h3()}, {"", nil}]
  end

  defp render_node({"p", _, children, _}, width) do
    text = extract_text(children)
    lines = word_wrap(text, width)
    Enum.map(lines, &{&1, nil}) ++ [{"", nil}]
  end

  defp render_node({"pre", _, [{"code", attrs, [code], _}], _}, width) do
    lang =
      case List.keyfind(attrs, "class", 0) do
        {"class", l} -> l
        _ -> nil
      end

    header = if lang, do: [{"  ┌─ #{lang} ", Theme.md_code_block()}], else: []

    code_lines =
      code
      |> String.split("\n")
      |> Enum.map(fn line ->
        {"  │ " <> String.slice(line, 0, max(1, width - 6)), Theme.md_code_block()}
      end)

    header ++ code_lines ++ [{"  └─", Theme.md_code_block()}, {"", nil}]
  end

  defp render_node({"pre", _, children, _}, width) do
    text = extract_text(children)
    lines = String.split(text, "\n")

    Enum.map(lines, &{"  " <> String.slice(&1, 0, max(1, width - 4)), Theme.md_code_block()}) ++
      [{"", nil}]
  end

  defp render_node({"ul", _, items, _}, width) do
    list_lines =
      Enum.flat_map(items, fn
        {"li", _, children, _} ->
          t = extract_text(children)

          case parse_task_marker(t) do
            {:task, :done, rest} ->
              render_task_li("☑", rest, width, Theme.muted())

            {:task, :todo, rest} ->
              render_task_li("☐", rest, width, Theme.normal())

            :no_task ->
              render_bullet_li(t, width)
          end

        _ ->
          []
      end)

    list_lines ++ [{"", nil}]
  end

  defp render_node({"ol", _, items, _}, width) do
    list_lines =
      items
      |> Enum.with_index(1)
      |> Enum.flat_map(fn
        {{"li", _, children, _}, n} ->
          t = extract_text(children)
          prefix = "  #{n}. "
          lines = word_wrap(t, max(1, width - String.length(prefix)))

          case lines do
            [first | rest] ->
              [
                {prefix <> first, nil}
                | Enum.map(rest, &{String.duplicate(" ", String.length(prefix)) <> &1, nil})
              ]

            [] ->
              [{prefix, nil}]
          end

        _ ->
          []
      end)

    list_lines ++ [{"", nil}]
  end

  defp render_node({"blockquote", _, children, _}, width) do
    children
    |> Enum.flat_map(&render_node(&1, max(1, width - 4)))
    |> Enum.map(fn {text, style} -> {"  │ " <> text, style || Theme.muted()} end)
  end

  defp render_node({"hr", _, _, _}, width) do
    [{"  " <> String.duplicate("─", max(1, width - 4)), Theme.separator()}, {"", nil}]
  end

  defp render_node({"table", _, children, _}, width) do
    Egghead.TUI.Markdown.Table.render(children, width)
  end

  # Footnotes section: <div class="footnotes"><hr/><ol>...</ol></div>
  defp render_node({"div", attrs, children, _}, width) do
    case List.keyfind(attrs, "class", 0) do
      {"class", "footnotes"} ->
        render_footnotes_section(children, width)

      _ ->
        Enum.flat_map(children, &render_node(&1, width))
    end
  end

  # Inline elements that appear at block level (shouldn't happen often)
  defp render_node(text, _width) when is_binary(text) do
    [{text, nil}]
  end

  # Unknown tags — just extract text
  defp render_node({_tag, _, children, _}, width) do
    text = extract_text(children)
    lines = word_wrap(text, width)
    Enum.map(lines, &{&1, nil}) ++ [{"", nil}]
  end

  defp render_node(_, _width), do: []

  # --- List item helpers ---

  # Task list detection — Earmark doesn't recognize GFM task syntax, so we
  # detect "[ ] " / "[x] " / "[X] " as the leading text of an <li>.
  defp parse_task_marker("[ ] " <> rest), do: {:task, :todo, rest}
  defp parse_task_marker("[x] " <> rest), do: {:task, :done, rest}
  defp parse_task_marker("[X] " <> rest), do: {:task, :done, rest}
  defp parse_task_marker(_), do: :no_task

  defp render_task_li(checkbox, text, width, style) do
    prefix = "  #{checkbox} "
    lines = word_wrap(text, max(1, width - String.length(prefix)))

    case lines do
      [first | rest] ->
        [{prefix <> first, style}] ++
          Enum.map(rest, fn ln ->
            {String.duplicate(" ", String.length(prefix)) <> ln, style}
          end)

      [] ->
        [{prefix, style}]
    end
  end

  defp render_bullet_li(text, width) do
    lines = word_wrap(text, max(1, width - 4))

    case lines do
      [first | rest] ->
        [{"  · " <> first, nil} | Enum.map(rest, &{"    " <> &1, nil})]

      [] ->
        [{"  ·", nil}]
    end
  end

  # --- Footnotes section ---

  defp render_footnotes_section(children, width) do
    items =
      children
      |> Enum.flat_map(fn
        {"ol", _, lis, _} -> lis
        _ -> []
      end)

    header = [
      {"", nil},
      {"── Footnotes ──", Theme.separator()},
      {"", nil}
    ]

    rendered =
      items
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {{"li", attrs, content, _}, n} ->
        # Strip the reversefootnote anchor that Earmark prepends
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

        # Render footnote body inline (paragraph children only)
        body_text =
          content
          |> Enum.map_join(" ", fn
            {"p", _, kids, _} -> extract_text(kids)
            other -> extract_text([other])
          end)
          |> String.trim()

        prefix = "  [#{id}] "
        wrap_w = max(1, width - String.length(prefix))
        lines = word_wrap(body_text, wrap_w)

        case lines do
          [first | rest] ->
            [{prefix <> first, Theme.muted()}] ++
              Enum.map(rest, fn ln ->
                {String.duplicate(" ", String.length(prefix)) <> ln, Theme.muted()}
              end)

          [] ->
            [{prefix, Theme.muted()}]
        end
      end)

    header ++ rendered ++ [{"", nil}]
  end

  # --- Text extraction (flattens inline markup) ---

  defp extract_text(children) when is_list(children) do
    Enum.map_join(children, "", &extract_text_node/1)
  end

  defp extract_text(text) when is_binary(text), do: text
  defp extract_text(_), do: ""

  defp extract_text_node(text) when is_binary(text), do: text
  defp extract_text_node({"strong", _, children, _}), do: extract_text(children)
  defp extract_text_node({"em", _, children, _}), do: extract_text(children)
  defp extract_text_node({"code", _, children, _}), do: extract_text(children)

  # Wikilink: render as [[target]] or [[target|display]]
  defp extract_text_node({"a", attrs, children, %{wikilink: true}}) do
    target = attrs_get(attrs, "href", "")
    display = extract_text(children)
    if display == "" or display == target, do: "[[#{target}]]", else: "[[#{target}|#{display}]]"
  end

  # Footnote reference: render as ^[id]
  defp extract_text_node({"a", attrs, [id], _meta}) when is_binary(id) do
    case attrs_get(attrs, "class", "") do
      "footnote" -> "^[#{id}]"
      _ -> id
    end
  end

  defp extract_text_node({"a", _, children, _}), do: extract_text(children)
  defp extract_text_node({"br", _, _, _}), do: "\n"
  defp extract_text_node({"sub", _, children, _}), do: "_" <> extract_text(children)
  defp extract_text_node({"sup", _, children, _}), do: "^" <> extract_text(children)
  defp extract_text_node({_tag, _, children, _}), do: extract_text(children)
  defp extract_text_node(_), do: ""

  defp attrs_get(attrs, key, default) do
    case List.keyfind(attrs, key, 0) do
      {^key, value} -> value
      _ -> default
    end
  end

  # --- Word wrap ---

  defp word_wrap(text, width) when width <= 0, do: [text]

  defp word_wrap(text, width) do
    text
    |> String.split("\n")
    |> Enum.flat_map(&wrap_line(&1, width))
  end

  defp wrap_line("", _width), do: [""]

  defp wrap_line(line, width) do
    words = String.split(line, " ")

    {lines, current} =
      Enum.reduce(words, {[], ""}, fn word, {lines, current} ->
        candidate =
          if current == "", do: word, else: current <> " " <> word

        if String.length(candidate) <= width do
          {lines, candidate}
        else
          if current == "" do
            # Single word longer than width — force it
            {lines ++ [String.slice(word, 0, width)], ""}
          else
            {lines ++ [current], word}
          end
        end
      end)

    if current == "", do: lines, else: lines ++ [current]
  end
end
