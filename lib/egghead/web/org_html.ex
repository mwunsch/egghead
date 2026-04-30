defmodule Egghead.Web.OrgHTML do
  @moduledoc """
  Renders an org-mode body to HTML, walking the `Egghead.Record.OrgParser`
  AST and emitting HTML that **looks like org-mode**. Headlines keep their
  stars, TODO keywords render as styled badges, property drawers show as
  visible `<dl>` blocks, source blocks are framed by their `#+BEGIN_SRC` /
  `#+END_SRC` markers, timestamps keep their angle/square brackets, and
  `[[target]]` links round-trip with the `data-wikilink` attribute that
  the LiveView already understands.

  This is **not** a markdown renderer in disguise. The emitted HTML
  preserves the structural artifacts of an org document so org-mode users
  recognise their files on the web. Class names use the `org-` prefix so
  the site CSS can theme them independently of the markdown renderer's
  output.

  ## Wikilink contract

  Org `[[target][display]]` links whose target looks like a record id
  (no `://`, no leading `/`) are emitted as `<a class="org-link wikilink"
  data-wikilink="target">…</a>` so the existing client-side navigation in
  `Egghead.Web.Live.AppLive` works on org records without a separate path.

  External org links (e.g. `[[https://…]]`) emit a normal `<a>`.
  """

  alias Egghead.Record.OrgParser

  @doc """
  Render an org-mode body string to HTML.

  Accepts the same `:link_fn` / `:exists_fn` options as
  `Egghead.Web.MarkdownHTML.render/2` so wikilink hrefs and
  missing-target classes line up across formats.
  """
  @spec render(String.t(), keyword()) :: String.t()
  def render(body, opts \\ []) when is_binary(body) do
    link_fn = Keyword.get(opts, :link_fn, &default_link/1)
    exists_fn = Keyword.get(opts, :exists_fn, fn _ -> true end)

    case OrgParser.parse(body) do
      {:ok, ast} ->
        ast
        |> Enum.map(&render_block(&1, link_fn, exists_fn))
        |> IO.iodata_to_binary()

      _ ->
        "<pre>" <> escape(body) <> "</pre>"
    end
  rescue
    _ -> "<pre>" <> escape(body) <> "</pre>"
  end

  defp default_link(target), do: "/records/#{target}"

  # --- Block-level nodes ---

  defp render_block({:headline, meta, _children}, _link_fn, _exists_fn) do
    %{level: level, title: title, keyword: keyword, priority: priority, tags: tags} = meta
    tag = "h#{min(level, 6)}"
    stars = String.duplicate("*", level)

    keyword_html =
      if keyword,
        do:
          "<span class=\"org-todo org-todo-#{String.downcase(keyword)}\">#{escape(keyword)}</span>",
        else: ""

    priority_html =
      if priority,
        do: "<span class=\"org-priority\">[#" <> escape(priority) <> "]</span>",
        else: ""

    tags_html =
      case tags do
        [] ->
          ""

        list ->
          Enum.map_join(list, "", fn t ->
            "<span class=\"org-tag\">" <> escape(t) <> "</span>"
          end)
          |> then(&"<span class=\"org-tags\">#{&1}</span>")
      end

    parts =
      [
        "<span class=\"org-stars\">#{stars}</span>",
        keyword_html,
        priority_html,
        "<span class=\"org-headline-text\">" <> escape(title) <> "</span>",
        tags_html
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    "<#{tag} class=\"org-headline\" data-level=\"#{level}\">#{parts}</#{tag}>\n"
  end

  defp render_block({:keyword, %{key: key, value: value}, _}, _link_fn, _exists_fn) do
    # Keywords like #+TITLE, #+AUTHOR, #+DATE, #+OPTIONS appear visibly so
    # the rendered view shows what the file says. The site CSS can hide
    # the title keyword if a heading is preferred.
    "<div class=\"org-keyword\" data-key=\"" <>
      escape_attr(key) <>
      "\"><span class=\"org-keyword-key\">#+" <>
      escape(key) <>
      ":</span> <span class=\"org-keyword-value\">" <>
      escape(value) <>
      "</span></div>\n"
  end

  defp render_block({:property_drawer, _, props}, _link_fn, _exists_fn) do
    body =
      Enum.map_join(props, "", fn {k, v} ->
        "<div class=\"org-property\"><span class=\"org-property-key\">:" <>
          escape(k) <>
          ":</span> <span class=\"org-property-value\">" <> escape(v) <> "</span></div>"
      end)

    "<div class=\"org-property-drawer\">" <>
      "<div class=\"org-drawer-marker\">:PROPERTIES:</div>" <>
      body <>
      "<div class=\"org-drawer-marker\">:END:</div>" <>
      "</div>\n"
  end

  defp render_block({:src_block, %{language: lang}, content}, _link_fn, _exists_fn) do
    lang_attr = if lang, do: " data-language=\"#{escape_attr(lang)}\"", else: ""
    lang_label = if lang, do: " " <> escape(lang), else: ""
    code_class = if lang, do: " class=\"language-#{escape_attr(lang)}\"", else: ""

    "<div class=\"org-src-block\"#{lang_attr}>" <>
      "<div class=\"org-block-marker org-block-begin\">#+BEGIN_SRC#{lang_label}</div>" <>
      "<pre class=\"org-src\"><code#{code_class}>" <>
      escape(content) <>
      "</code></pre>" <>
      "<div class=\"org-block-marker org-block-end\">#+END_SRC</div>" <>
      "</div>\n"
  end

  defp render_block({:example_block, _, content}, _link_fn, _exists_fn) do
    "<div class=\"org-example-block\">" <>
      "<div class=\"org-block-marker org-block-begin\">#+BEGIN_EXAMPLE</div>" <>
      "<pre class=\"org-example\">" <>
      escape(content) <>
      "</pre>" <>
      "<div class=\"org-block-marker org-block-end\">#+END_EXAMPLE</div>" <>
      "</div>\n"
  end

  defp render_block({:quote_block, _, inner}, link_fn, exists_fn) do
    body =
      inner
      |> Enum.map(&render_block(&1, link_fn, exists_fn))
      |> IO.iodata_to_binary()

    "<blockquote class=\"org-quote\">#{body}</blockquote>\n"
  end

  defp render_block({:plain_list, _, items}, link_fn, exists_fn) do
    list_tag =
      case items do
        [{:list_item, %{bullet: bullet}, _} | _] when is_binary(bullet) ->
          if String.match?(bullet, ~r/^\d/), do: "ol", else: "ul"

        _ ->
          "ul"
      end

    body =
      Enum.map_join(items, "", fn item -> render_list_item(item, link_fn, exists_fn) end)

    "<#{list_tag} class=\"org-list\">#{body}</#{list_tag}>\n"
  end

  defp render_block({:paragraph, _, inline}, link_fn, exists_fn) do
    "<p class=\"org-paragraph\">" <>
      render_inline(inline, link_fn, exists_fn) <>
      "</p>\n"
  end

  # Fallback for any tagged block we don't explicitly handle.
  defp render_block({_tag, _meta, _children}, _link_fn, _exists_fn), do: ""
  defp render_block(text, _link_fn, _exists_fn) when is_binary(text), do: escape(text)
  defp render_block(_, _, _), do: ""

  defp render_list_item({:list_item, %{checkbox: checkbox}, inline}, link_fn, exists_fn) do
    {prefix, classes} =
      case checkbox do
        :checked ->
          {"<input type=\"checkbox\" checked disabled /> ", " org-task org-task-done"}

        :partial ->
          {"<input type=\"checkbox\" disabled /> ", " org-task org-task-partial"}

        :unchecked ->
          {"<input type=\"checkbox\" disabled /> ", " org-task org-task-todo"}

        _ ->
          {"", ""}
      end

    "<li class=\"org-list-item#{classes}\">#{prefix}#{render_inline(inline, link_fn, exists_fn)}</li>"
  end

  # --- Inline elements ---

  defp render_inline(elements, link_fn, exists_fn) when is_list(elements) do
    elements
    |> Enum.map(&render_inline_one(&1, link_fn, exists_fn))
    |> IO.iodata_to_binary()
  end

  defp render_inline_one({:text, text}, _, _), do: escape(text)
  defp render_inline_one({:bold, text}, _, _), do: "<strong>" <> escape(text) <> "</strong>"
  defp render_inline_one({:italic, text}, _, _), do: "<em>" <> escape(text) <> "</em>"

  defp render_inline_one({:code, text}, _, _),
    do: "<code class=\"org-code\">" <> escape(text) <> "</code>"

  defp render_inline_one({:verbatim, text}, _, _),
    do: "<code class=\"org-verbatim\">" <> escape(text) <> "</code>"

  defp render_inline_one({:underline, text}, _, _),
    do: "<span class=\"org-underline\">" <> escape(text) <> "</span>"

  defp render_inline_one({:strikethrough, text}, _, _),
    do: "<del>" <> escape(text) <> "</del>"

  defp render_inline_one({:link, %{target: target, display: display}}, link_fn, exists_fn) do
    display_text = display || target

    cond do
      external?(target) ->
        "<a class=\"org-link\" href=\"" <>
          escape_attr(target) <>
          "\">" <> escape(display_text) <> "</a>"

      true ->
        href = link_fn.(target)
        exists? = exists_fn.(target)
        cls = if exists?, do: "org-link wikilink", else: "org-link wikilink missing"

        "<a class=\"#{cls}\" href=\"" <>
          escape_attr(href) <>
          "\" data-wikilink=\"" <>
          escape_attr(target) <>
          "\" data-phx-link=\"patch\" data-phx-link-state=\"push\">" <>
          escape(display_text) <>
          "</a>"
    end
  end

  defp render_inline_one({:timestamp, %{type: type, date: date, day: day, time: time}}, _, _) do
    {open, close} = if type == :active, do: {"<", ">"}, else: {"[", "]"}

    parts =
      [date, day, time]
      |> Enum.reject(&(&1 == nil or &1 == ""))
      |> Enum.join(" ")

    "<time class=\"org-ts org-ts-#{type}\">" <>
      escape(open) <>
      escape(parts) <>
      escape(close) <>
      "</time>"
  end

  defp render_inline_one(text, _, _) when is_binary(text), do: escape(text)
  defp render_inline_one(_, _, _), do: ""

  defp external?(target) do
    String.contains?(target, "://") or
      String.starts_with?(target, "/") or
      String.starts_with?(target, "mailto:") or
      String.starts_with?(target, "file:")
  end

  # --- Escaping ---

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape(other), do: escape(to_string(other))

  defp escape_attr(text), do: escape(text)
end
