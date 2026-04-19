defmodule Egghead.Web.MarkdownHTML do
  @moduledoc """
  Render markdown to HTML with wikilink support.

  Walks the same Earmark AST that `Egghead.OpenTUI.Markdown` uses
  (identical `@earmark_opts`), but emits HTML instead of styled
  terminal spans. Wikilinks become `<a>` tags with
  `data-wikilink="target"` attributes for client-side navigation.
  """

  @earmark_opts [wikilinks: true, gfm_tables: true, footnotes: true, sub_sup: true]

  @doc """
  Render a markdown string to an HTML string.

  Options:
    * `:link_fn` — function `(target :: String.t()) -> href :: String.t()`.
      Defaults to `"/?id=\#{target}"`. Used for wikilink hrefs.
    * `:exists_fn` — function `(target :: String.t()) -> boolean()`.
      When provided, dangling wikilinks get a `missing` CSS class.
  """
  @spec render(String.t(), keyword()) :: String.t()
  def render(markdown, opts \\ []) when is_binary(markdown) do
    link_fn = Keyword.get(opts, :link_fn, &default_link/1)
    exists_fn = Keyword.get(opts, :exists_fn, fn _ -> true end)

    # Earmark returns `{:error, ast, warnings}` whenever it emits a
    # warning (common on real-world bodies — false-positive IAL
    # attribute parsing). The AST is still usable; fall back to
    # plaintext-in-a-pre only when no AST came back at all.
    case Earmark.as_ast(markdown, @earmark_opts) do
      {:ok, ast, _} when is_list(ast) ->
        render_ast(ast, link_fn, exists_fn)

      {:error, ast, _} when is_list(ast) and ast != [] ->
        render_ast(ast, link_fn, exists_fn)

      _ ->
        "<pre>#{escape(markdown)}</pre>"
    end
  rescue
    _ -> "<pre>#{escape(markdown)}</pre>"
  end

  defp default_link(target), do: "/records/#{target}"

  defp render_ast(ast, link_fn, exists_fn) do
    ast
    |> Enum.map(&render_node(&1, link_fn, exists_fn))
    |> IO.iodata_to_binary()
  end

  # --- block nodes ---

  defp render_node(text, _link_fn, _exists_fn) when is_binary(text) do
    escape(text)
  end

  defp render_node({"h" <> _ = tag, attrs, children, meta}, link_fn, exists_fn)
       when tag in ~w(h1 h2 h3 h4 h5 h6) do
    wrap_tag(tag, attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"p", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("p", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"pre", _, [{"code", attrs, [code], _}], _}, _link_fn, _exists_fn)
       when is_binary(code) do
    lang =
      case List.keyfind(attrs, "class", 0) do
        {"class", lang} -> lang
        _ -> nil
      end

    lang_attr = if lang, do: " class=\"language-#{escape_attr(lang)}\"", else: ""
    data_lang = if lang, do: " data-lang=\"#{escape_attr(lang)}\"", else: ""

    "<pre#{data_lang}><code#{lang_attr}>#{escape(code)}</code></pre>\n"
  end

  defp render_node({"pre", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("pre", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"ul", _, items, _}, link_fn, exists_fn) do
    inner =
      Enum.map(items, fn
        {"li", _, children, _} ->
          plain = extract_plain_text(children)

          case parse_task_marker(plain) do
            {:task, :done, _} ->
              content = render_children(strip_task_text(children), link_fn, exists_fn)

              "<li class=\"task done\"><input type=\"checkbox\" checked disabled /> #{content}</li>\n"

            {:task, :todo, _} ->
              content = render_children(strip_task_text(children), link_fn, exists_fn)
              "<li class=\"task todo\"><input type=\"checkbox\" disabled /> #{content}</li>\n"

            :no_task ->
              "<li>#{render_children(children, link_fn, exists_fn)}</li>\n"
          end

        node ->
          render_node(node, link_fn, exists_fn)
      end)

    "<ul>\n#{inner}</ul>\n"
  end

  defp render_node({"ol", attrs, items, meta}, link_fn, exists_fn) do
    wrap_tag("ol", attrs, items, meta, link_fn, exists_fn)
  end

  defp render_node({"blockquote", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("blockquote", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"table", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("table", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"thead", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("thead", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"tbody", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("tbody", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"tr", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("tr", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"th", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("th", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"td", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("td", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"hr", _, _, _}, _link_fn, _exists_fn), do: "<hr />\n"

  # Inline elements
  defp render_node({"em", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("em", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"strong", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("strong", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"del", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("del", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"code", _, [code], _}, _link_fn, _exists_fn) when is_binary(code) do
    "<code>#{escape(code)}</code>"
  end

  defp render_node({"code", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("code", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"br", _, _, _}, _link_fn, _exists_fn), do: "<br />"

  # Wikilinks — Earmark marks them with %{wikilink: true}
  defp render_node({"a", attrs, children, %{wikilink: true}}, link_fn, exists_fn) do
    target =
      case List.keyfind(attrs, "href", 0) do
        {"href", t} -> t
        _ -> extract_plain_text(children)
      end

    display = render_children(children, link_fn, exists_fn)
    href = link_fn.(target)
    exists? = exists_fn.(target)
    class = if exists?, do: "wikilink", else: "wikilink missing"

    "<a href=\"#{escape_attr(href)}\" class=\"#{class}\" data-wikilink=\"#{escape_attr(target)}\" data-phx-link=\"patch\" data-phx-link-state=\"push\">#{display}</a>"
  end

  # Regular links
  defp render_node({"a", attrs, children, _meta}, link_fn, exists_fn) do
    href =
      case List.keyfind(attrs, "href", 0) do
        {"href", h} -> h
        _ -> "#"
      end

    display = render_children(children, link_fn, exists_fn)
    "<a href=\"#{escape_attr(href)}\">#{display}</a>"
  end

  # Footnote references
  defp render_node({"sup", _, [{"a", attrs, children, _}], _}, link_fn, exists_fn) do
    href =
      case List.keyfind(attrs, "href", 0) do
        {"href", h} -> h
        _ -> "#"
      end

    display = render_children(children, link_fn, exists_fn)
    "<sup><a href=\"#{escape_attr(href)}\" class=\"footnote-ref\">#{display}</a></sup>"
  end

  defp render_node({"sup", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("sup", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"sub", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("sub", attrs, children, meta, link_fn, exists_fn)
  end

  # Images
  defp render_node({"img", attrs, _, _}, _link_fn, _exists_fn) do
    src =
      case List.keyfind(attrs, "src", 0) do
        {"src", s} -> s
        _ -> ""
      end

    alt =
      case List.keyfind(attrs, "alt", 0) do
        {"alt", a} -> a
        _ -> ""
      end

    "<img src=\"#{escape_attr(src)}\" alt=\"#{escape_attr(alt)}\" />"
  end

  # Definition lists and other elements
  defp render_node({"dl", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("dl", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"dt", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("dt", attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node({"dd", attrs, children, meta}, link_fn, exists_fn) do
    wrap_tag("dd", attrs, children, meta, link_fn, exists_fn)
  end

  # Catch-all for unknown tags
  defp render_node({tag, attrs, children, meta}, link_fn, exists_fn) when is_binary(tag) do
    wrap_tag(tag, attrs, children, meta, link_fn, exists_fn)
  end

  defp render_node(_, _, _), do: ""

  # --- helpers ---

  defp wrap_tag(tag, _attrs, children, _meta, link_fn, exists_fn) do
    inner = render_children(children, link_fn, exists_fn)
    "<#{tag}>#{inner}</#{tag}>\n"
  end

  defp render_children(children, link_fn, exists_fn) do
    children
    |> Enum.map(&render_node(&1, link_fn, exists_fn))
    |> IO.iodata_to_binary()
  end

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape_attr(text) when is_binary(text), do: escape(text)

  # --- task list helpers ---

  defp extract_plain_text(nodes) when is_list(nodes) do
    Enum.map_join(nodes, "", &extract_plain_text/1)
  end

  defp extract_plain_text(text) when is_binary(text), do: text

  defp extract_plain_text({_tag, _attrs, children, _meta}) do
    extract_plain_text(children)
  end

  defp extract_plain_text(_), do: ""

  defp parse_task_marker(text) do
    cond do
      String.starts_with?(text, "[x] ") or String.starts_with?(text, "[X] ") ->
        {:task, :done, String.slice(text, 4..-1//1)}

      String.starts_with?(text, "[ ] ") ->
        {:task, :todo, String.slice(text, 4..-1//1)}

      true ->
        :no_task
    end
  end

  defp strip_task_text(children) do
    case children do
      [text | rest] when is_binary(text) ->
        stripped =
          text
          |> String.replace_leading("[x] ", "")
          |> String.replace_leading("[X] ", "")
          |> String.replace_leading("[ ] ", "")

        [stripped | rest]

      [{tag, attrs, [text | inner_rest], meta} | rest] when is_binary(text) ->
        stripped =
          text
          |> String.replace_leading("[x] ", "")
          |> String.replace_leading("[X] ", "")
          |> String.replace_leading("[ ] ", "")

        [{tag, attrs, [stripped | inner_rest], meta} | rest]

      other ->
        other
    end
  end
end
