defmodule Egghead.Record.OrgParser do
  @moduledoc """
  Parses org-mode document content into a structured AST.

  Uses NimbleParsec for inline element parsing (links, timestamps, markup)
  and line-by-line pattern matching for block structure (headlines, drawers,
  source blocks, lists).

  Reference grammar: https://orgmode.org/worg/dev/org-syntax.html

  ## AST Format

  The AST is a list of nodes. Each node is either a tagged tuple or a string:

      {:headline, %{level: 1, title: "...", keyword: nil, priority: nil, tags: []}, children}
      {:property_drawer, %{}, [{"KEY", "value"}, ...]}
      {:keyword, %{key: "TITLE", value: "..."}}
      {:paragraph, %{}, [inline_elements]}
      {:plain_list, %{}, [items]}
      {:list_item, %{bullet: "-", checkbox: nil, indent: 0}, [inline_elements]}
      {:src_block, %{language: "elixir"}, "code content"}
      {:example_block, %{}, "content"}
      {:quote_block, %{}, [block_elements]}
      {:link, %{target: "...", display: nil}}
      {:timestamp, %{type: :active, date: "2026-03-25", time: nil, day: nil}}
      {:text, "plain text"}
      {:bold, "text"}
      {:italic, "text"}
      {:code, "text"}
      {:verbatim, "text"}
      {:underline, "text"}
      {:strikethrough, "text"}
  """

  import NimbleParsec

  # --- Inline parsers (NimbleParsec) ---

  # Org-mode link: [[target]] or [[target][display]]
  # Characters ']' and '[' and newline are excluded from link targets/displays
  org_link_target = utf8_string([not: ?\], not: ?\[, not: ?\n], min: 1)
  org_link_desc = utf8_string([not: ?\], not: ?\[, not: ?\n], min: 1)

  org_link =
    ignore(string("[["))
    |> concat(org_link_target |> tag(:target))
    |> optional(
      ignore(string("]["))
      |> concat(org_link_desc |> tag(:display))
    )
    |> ignore(string("]]"))
    |> tag(:link)

  # Active timestamp: <2026-03-25 Tue 10:00>
  ts_date = utf8_string([?0..?9, ?-], 10)
  ts_day = optional(ignore(string(" ")) |> concat(utf8_string([?A..?Z, ?a..?z], min: 2, max: 3)))
  ts_time = optional(ignore(string(" ")) |> concat(utf8_string([?0..?9, ?:], min: 4, max: 8)))

  active_timestamp =
    ignore(string("<"))
    |> concat(ts_date |> tag(:date))
    |> concat(ts_day |> tag(:day))
    |> concat(ts_time |> tag(:time))
    |> ignore(utf8_string([not: ?>], min: 0))
    |> ignore(string(">"))
    |> tag(:active_timestamp)

  inactive_timestamp =
    ignore(string("["))
    |> concat(ts_date |> tag(:date))
    |> concat(ts_day |> tag(:day))
    |> concat(ts_time |> tag(:time))
    |> ignore(utf8_string([not: ?]], min: 0))
    |> ignore(string("]"))
    |> tag(:inactive_timestamp)

  # Text markup: *bold*, /italic/, ~code~, =verbatim=, _underline_, +strikethrough+
  bold_text =
    ignore(string("*"))
    |> concat(utf8_string([not: ?*, not: ?\n], min: 1))
    |> ignore(string("*"))
    |> tag(:bold)

  italic_text =
    ignore(string("/"))
    |> concat(utf8_string([not: ?/, not: ?\n], min: 1))
    |> ignore(string("/"))
    |> tag(:italic)

  code_text =
    ignore(string("~"))
    |> concat(utf8_string([not: ?~, not: ?\n], min: 1))
    |> ignore(string("~"))
    |> tag(:code)

  verbatim_text =
    ignore(string("="))
    |> concat(utf8_string([not: ?=, not: ?\n], min: 1))
    |> ignore(string("="))
    |> tag(:verbatim)

  underline_text =
    ignore(string("_"))
    |> concat(utf8_string([not: ?_, not: ?\n], min: 1))
    |> ignore(string("_"))
    |> tag(:underline)

  strikethrough_text =
    ignore(string("+"))
    |> concat(utf8_string([not: ?+, not: ?\n], min: 1))
    |> ignore(string("+"))
    |> tag(:strikethrough)

  inline_element =
    choice([
      org_link,
      active_timestamp,
      inactive_timestamp,
      bold_text,
      italic_text,
      code_text,
      verbatim_text,
      underline_text,
      strikethrough_text
    ])

  # Plain text: consume characters that can't start a markup element
  plain_char =
    utf8_string(
      [not: ?\n, not: ?\[, not: ?<, not: ?*, not: ?/, not: ?~, not: ?=, not: ?_, not: ?+],
      1
    )

  # A markup start char that didn't match any markup rule — consume as text
  failed_markup_char = utf8_string([?[, ?<, ?*, ?/, ?~, ?=, ?_, ?+], 1)

  # Parse as many inline elements as possible from a line
  defparsec(
    :parse_inline,
    repeat(
      choice([
        inline_element,
        # Non-markup plain text (fast path)
        plain_char |> tag(:text_char),
        # Markup char that didn't match any rule (fallback)
        failed_markup_char |> tag(:text_char)
      ])
    )
  )

  # --- Public API ---

  @doc """
  Parses org-mode content into an AST.
  """
  @spec parse(String.t()) :: {:ok, list()}
  def parse(content) do
    lines = String.split(content, "\n")
    {ast, _state} = parse_lines(lines, [], %{in_block: nil})
    {:ok, Enum.reverse(ast)}
  end

  @doc """
  Extracts the title — from #+TITLE keyword or first level-1 headline.
  """
  @spec extract_title(list()) :: String.t() | nil
  def extract_title(ast) do
    # First try #+TITLE keyword
    # Fall back to first headline
    Enum.find_value(ast, fn
      {:keyword, %{key: "TITLE", value: value}, _} -> value
      _ -> nil
    end) ||
      Enum.find_value(ast, fn
        {:headline, %{level: 1, title: title}, _} -> title
        _ -> nil
      end)
  end

  @doc """
  Extracts an outline of all headlines.
  """
  @spec extract_outline(list()) :: [%{level: non_neg_integer(), text: String.t()}]
  def extract_outline(ast) do
    Enum.flat_map(ast, fn
      {:headline, %{level: level, title: title}, _} ->
        [%{level: level, text: title}]

      _ ->
        []
    end)
  end

  @doc """
  Extracts all org-mode links from the AST (recursive).

  Org links use `[[target][display]]` syntax.
  Returns the same wikilink format as the markdown AST module.
  """
  @spec extract_links(list()) :: [Egghead.Record.wikilink()]
  def extract_links(ast) do
    collect_links(ast, []) |> Enum.reverse()
  end

  @doc """
  Returns the body of an org file with the file-level preamble stripped:
  the contiguous block of `#+`-keywords and `#`-comments at the top, and
  the first `:PROPERTIES:` drawer if it appears before any headline.

  Used to project an org agent record's body into a system prompt: the
  on-disk file keeps every `#+TITLE:` and drawer entry (those are the
  document), but the prompt the model sees is the prose part starting
  from the first real content.

  This is a *projection*; the source file is unchanged.
  """
  @spec body_without_preamble(String.t()) :: String.t()
  def body_without_preamble(content) when is_binary(content) do
    lines = String.split(content, "\n")
    {_skipped, rest} = drop_keyword_prefix(lines)
    {_drawer, rest} = drop_leading_drawer(rest)

    rest
    |> Enum.drop_while(&blank?/1)
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  defp drop_keyword_prefix(lines) do
    Enum.split_while(lines, fn line ->
      Regex.match?(~r/^[ \t]*#\+\w+:/, line) or
        Regex.match?(~r/^[ \t]*#[^+]/, line) or
        blank?(line)
    end)
  end

  # If the next non-blank line opens a properties drawer (and no headline
  # has appeared), consume up to the matching :END:. Headline-attached
  # drawers belong to that subtree and are left in place.
  defp drop_leading_drawer(lines) do
    {leading_blanks, rest} = Enum.split_while(lines, &blank?/1)

    case rest do
      [first | tail] ->
        if Regex.match?(~r/^[ \t]*:PROPERTIES:[ \t]*$/, first) do
          case Enum.split_while(tail, fn l -> not Regex.match?(~r/^[ \t]*:END:[ \t]*$/, l) end) do
            {drawer_lines, [end_line | after_end]} ->
              {[first | drawer_lines] ++ [end_line], after_end}

            {_drawer_lines, []} ->
              # Unterminated drawer — leave content alone.
              {[], leading_blanks ++ rest}
          end
        else
          {[], leading_blanks ++ rest}
        end

      [] ->
        {[], leading_blanks}
    end
  end

  defp blank?(line), do: Regex.match?(~r/^\s*$/, line)

  @doc """
  Extracts all source blocks from the AST.
  """
  @spec extract_code_blocks(list()) :: [%{language: String.t() | nil, content: String.t()}]
  def extract_code_blocks(ast) do
    Enum.flat_map(ast, fn
      {:src_block, %{language: lang}, content} ->
        [%{language: lang, content: content}]

      _ ->
        []
    end)
  end

  # --- Line-by-line parser ---

  defp parse_lines([], acc, _state), do: {acc, %{in_block: nil}}

  # Source block begin
  defp parse_lines([line | rest], acc, %{in_block: nil} = state) do
    cond do
      src_block_begin?(line) ->
        {lang, _params} = parse_block_begin(line)
        {content, rest} = collect_block(rest, [])
        node = {:src_block, %{language: lang}, content}
        parse_lines(rest, [node | acc], state)

      example_block_begin?(line) ->
        {content, rest} = collect_block(rest, [])
        node = {:example_block, %{}, content}
        parse_lines(rest, [node | acc], state)

      quote_block_begin?(line) ->
        {content, rest} = collect_block(rest, [])
        # Parse inner content of quote blocks
        {:ok, inner_ast} = parse(content)
        node = {:quote_block, %{}, inner_ast}
        parse_lines(rest, [node | acc], state)

      property_drawer_begin?(line) ->
        {props, rest} = collect_property_drawer(rest, [])
        node = {:property_drawer, %{}, props}
        parse_lines(rest, [node | acc], state)

      headline?(line) ->
        node = parse_headline(line)
        parse_lines(rest, [node | acc], state)

      keyword_line?(line) ->
        node = parse_keyword(line)
        parse_lines(rest, [node | acc], state)

      list_item_line?(line) ->
        {items, rest} = collect_list_items([line | rest], [])
        node = {:plain_list, %{}, Enum.reverse(items)}
        parse_lines(rest, [node | acc], state)

      blank_line?(line) ->
        parse_lines(rest, acc, state)

      true ->
        {para_lines, rest} = collect_paragraph([line | rest], [])
        # Join with a single space so the inline parser (whose tokens
        # exclude `\n`) sees one logical line. Org treats line breaks
        # within a paragraph as soft — they render as spaces, like
        # markdown — so collapsing is correct, and it lets bold/italic/
        # link parsing work across visually-wrapped source lines.
        inline = parse_inline_text(Enum.map_join(para_lines, " ", &String.trim_trailing/1))
        node = {:paragraph, %{}, inline}
        parse_lines(rest, [node | acc], state)
    end
  end

  # --- Line classifiers ---

  defp headline?(line), do: Regex.match?(~r/^\*+ /, line)
  defp keyword_line?(line), do: Regex.match?(~r/^\s*#\+\w+:/, line)
  defp property_drawer_begin?(line), do: Regex.match?(~r/^\s*:PROPERTIES:\s*$/, line)
  defp src_block_begin?(line), do: Regex.match?(~r/^\s*#\+(BEGIN_SRC|begin_src)/i, line)

  defp example_block_begin?(line),
    do: Regex.match?(~r/^\s*#\+(BEGIN_EXAMPLE|begin_example)/i, line)

  defp quote_block_begin?(line), do: Regex.match?(~r/^\s*#\+(BEGIN_QUOTE|begin_quote)/i, line)
  defp block_end?(line), do: Regex.match?(~r/^\s*#\+(END_|end_)/i, line)
  defp drawer_end?(line), do: Regex.match?(~r/^\s*:END:\s*$/i, line)
  defp blank_line?(line), do: Regex.match?(~r/^\s*$/, line)

  defp list_item_line?(line) do
    Regex.match?(~r/^(\s*)([-+*]|\d+[.)])\s/, line)
  end

  # --- Headline parser ---

  defp parse_headline(line) do
    {stars, rest} = parse_stars(line)
    level = String.length(stars)
    rest = String.trim(rest)

    {keyword, rest} = extract_todo_keyword(rest)
    {priority, rest} = extract_priority(rest)
    {tags, title} = extract_tags(rest)

    {:headline,
     %{level: level, title: String.trim(title), keyword: keyword, priority: priority, tags: tags},
     []}
  end

  defp parse_stars(line) do
    case Regex.run(~r/^(\*+)\s(.*)$/, line) do
      [_, stars, rest] -> {stars, rest}
      _ -> {"*", line}
    end
  end

  @todo_keywords ~w(TODO DONE NEXT WAITING CANCELLED HOLD)

  defp extract_todo_keyword(text) do
    case Regex.run(~r/^([A-Z]+)\s+(.*)$/, text) do
      [_, word, rest] ->
        if word in @todo_keywords, do: {word, rest}, else: {nil, text}

      _ ->
        {nil, text}
    end
  end

  defp extract_priority(text) do
    case Regex.run(~r/^\[#([A-Z])\]\s*(.*)$/, text) do
      [_, priority, rest] -> {priority, rest}
      _ -> {nil, text}
    end
  end

  defp extract_tags(text) do
    case Regex.run(~r/^(.*?)\s+:([\w:@#%]+):\s*$/, text) do
      [_, title, tag_str] ->
        tags = tag_str |> String.split(":") |> Enum.reject(&(&1 == ""))
        {tags, title}

      _ ->
        {[], text}
    end
  end

  # --- Keyword parser ---

  defp parse_keyword(line) do
    case Regex.run(~r/^\s*#\+(\w+):\s*(.*)$/, line) do
      [_, key, value] ->
        {:keyword, %{key: String.upcase(key), value: String.trim(value)}, []}

      _ ->
        {:keyword, %{key: "", value: ""}, []}
    end
  end

  # --- Block collectors ---

  defp collect_block([], acc) do
    {acc |> Enum.reverse() |> Enum.join("\n"), []}
  end

  defp collect_block([line | rest], acc) do
    if block_end?(line) do
      {acc |> Enum.reverse() |> Enum.join("\n"), rest}
    else
      collect_block(rest, [line | acc])
    end
  end

  defp collect_property_drawer([], acc), do: {Enum.reverse(acc), []}

  defp collect_property_drawer([line | rest], acc) do
    if drawer_end?(line) do
      {Enum.reverse(acc), rest}
    else
      case Regex.run(~r/^\s*:([^\s:]+):\s*(.*)$/, String.trim(line)) do
        [_, key, value] ->
          collect_property_drawer(rest, [{key, String.trim(value)} | acc])

        _ ->
          collect_property_drawer(rest, acc)
      end
    end
  end

  # --- List collector ---

  defp collect_list_items([], acc), do: {acc, []}

  defp collect_list_items([line | rest], acc) do
    if list_item_line?(line) do
      item = parse_list_item(line)
      collect_list_items(rest, [item | acc])
    else
      {acc, [line | rest]}
    end
  end

  defp parse_list_item(line) do
    case Regex.run(~r/^(\s*)([-+*]|\d+[.)])\s+(\[(.)\]\s+)?(.*)$/, line) do
      [_, indent, bullet, _, checkbox_char, content] ->
        checkbox = parse_checkbox(checkbox_char)
        inline = parse_inline_text(content)
        {:list_item, %{bullet: bullet, checkbox: checkbox, indent: String.length(indent)}, inline}

      [_, indent, bullet, _, content] ->
        inline = parse_inline_text(content)
        {:list_item, %{bullet: bullet, checkbox: nil, indent: String.length(indent)}, inline}

      _ ->
        inline = parse_inline_text(String.trim(line))
        {:list_item, %{bullet: "-", checkbox: nil, indent: 0}, inline}
    end
  end

  defp parse_checkbox("X"), do: :checked
  defp parse_checkbox("-"), do: :partial
  defp parse_checkbox(" "), do: :unchecked
  defp parse_checkbox(_), do: nil

  # --- Paragraph collector ---

  defp collect_paragraph([], acc), do: {Enum.reverse(acc), []}

  defp collect_paragraph([line | rest], acc) do
    cond do
      blank_line?(line) -> {Enum.reverse(acc), rest}
      headline?(line) -> {Enum.reverse(acc), [line | rest]}
      keyword_line?(line) -> {Enum.reverse(acc), [line | rest]}
      property_drawer_begin?(line) -> {Enum.reverse(acc), [line | rest]}
      src_block_begin?(line) -> {Enum.reverse(acc), [line | rest]}
      example_block_begin?(line) -> {Enum.reverse(acc), [line | rest]}
      quote_block_begin?(line) -> {Enum.reverse(acc), [line | rest]}
      list_item_line?(line) -> {Enum.reverse(acc), [line | rest]}
      true -> collect_paragraph(rest, [line | acc])
    end
  end

  # --- Inline text parser ---

  defp parse_inline_text(text) do
    case parse_inline(text) do
      {:ok, elements, "", _, _, _} ->
        elements
        |> merge_text_chars()
        |> Enum.map(&normalize_inline/1)

      _ ->
        [{:text, text}]
    end
  end

  # Merge consecutive {:text_char, ["x"]} into {:text, "xyz"}
  defp merge_text_chars(elements) do
    elements
    |> Enum.chunk_while(
      nil,
      fn
        {:text_char, [char]}, nil -> {:cont, {:text_chars, [char]}}
        {:text_char, [char]}, {:text_chars, chars} -> {:cont, {:text_chars, [char | chars]}}
        {:text_char, [char]}, other -> {:cont, other, {:text_chars, [char]}}
        elem, nil -> {:cont, elem}
        elem, {:text_chars, _} = chars -> {:cont, chars, elem}
        elem, other -> {:cont, other, elem}
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_inline({:text_chars, chars}) do
    {:text, chars |> Enum.reverse() |> Enum.join("")}
  end

  defp normalize_inline({:link, parts}) do
    target = parts |> Keyword.get(:target, []) |> Enum.join("")
    display = parts |> Keyword.get(:display, []) |> Enum.join("")
    {:link, %{target: target, display: if(display == "", do: nil, else: display)}}
  end

  defp normalize_inline({:active_timestamp, parts}) do
    normalize_timestamp(parts, :active)
  end

  defp normalize_inline({:inactive_timestamp, parts}) do
    normalize_timestamp(parts, :inactive)
  end

  defp normalize_inline({tag, [content]})
       when tag in [:bold, :italic, :code, :verbatim, :underline, :strikethrough] do
    {tag, content}
  end

  defp normalize_inline(other), do: other

  defp normalize_timestamp(parts, type) do
    date = parts |> Keyword.get(:date, []) |> Enum.join("")
    day = parts |> Keyword.get(:day, []) |> Enum.join("")
    time = parts |> Keyword.get(:time, []) |> Enum.join("")

    {:timestamp,
     %{
       type: type,
       date: date,
       day: if(day == "", do: nil, else: day),
       time: if(time == "", do: nil, else: time)
     }}
  end

  # --- Block begin parser ---

  defp parse_block_begin(line) do
    case Regex.run(~r/^\s*#\+(?:BEGIN_SRC|begin_src)\s*(.*)?$/i, line) do
      [_, params] ->
        parts = String.split(String.trim(params), ~r/\s+/, parts: 2)

        case parts do
          [lang | _] when lang != "" -> {lang, params}
          _ -> {nil, params}
        end

      _ ->
        {nil, ""}
    end
  end

  # --- Link collector (recursive AST walk) ---

  defp collect_links([], acc), do: acc

  defp collect_links([node | rest], acc) do
    acc = collect_links_from_node(node, acc)
    collect_links(rest, acc)
  end

  defp collect_links_from_node({:link, %{target: target, display: desc}}, acc) do
    {clean_target, fragment} = split_fragment(target)

    [%{target: clean_target, display: desc, fragment: fragment} | acc]
  end

  defp collect_links_from_node({_tag, _meta, children}, acc) when is_list(children) do
    collect_links(children, acc)
  end

  defp collect_links_from_node(_, acc), do: acc

  defp split_fragment(target) do
    case String.split(target, "#", parts: 2) do
      [t, f] -> {t, f}
      [t] -> {t, nil}
    end
  end
end
