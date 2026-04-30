defmodule Egghead.Record.OrgWriter do
  @moduledoc """
  Writer for org-mode records. Two distinct paths:

  - `new/1` — render a brand-new record from attrs as a minimal org skeleton
    (`#+TITLE:` block + body).
  - `splice_metadata/2` — apply caller attrs to an *existing* on-disk org file
    by editing only the affected `#+`-keyword lines and properties drawer
    entries. The rest of the file is left byte-identical: blank lines, casing
    of the user's `#+title:` vs `#+TITLE:`, ordering, comments, headlines —
    all preserved.

  This is the writer counterpart to `Egghead.Record.Parser.parse_org/2`.
  Together they enforce the rule that for org files, **the file on disk is
  the document**. Egghead never re-renders an org file from scratch on save.

  ## Why targeted splicing instead of a re-render

  YAML frontmatter is structural; we can pull it out, edit, and emit fresh
  YAML on every save without bothering the user. Org `#+`-keywords and
  property drawers are *part of the document*. A re-render would normalize
  whitespace, change keyword casing, reorder keys, and drop unknown fields
  the parser didn't promote to metadata. That breaks CRDT byte-identity and
  surprises org users who expect their files to stay theirs.
  """

  @doc """
  Renders a new org file from attrs. Used when creating a record from
  scratch (no existing file to preserve).

  Generates a minimal preamble — `#+TITLE`, `#+AUTHOR`, `#+FILETAGS`, plus
  a small `:PROPERTIES:` drawer for `id`/`links`/`class` and any extra
  meta — followed by the body. Written exactly once; subsequent updates
  use `splice_metadata/2` to mutate in place.
  """
  @spec new(map()) :: String.t()
  def new(attrs) do
    id = attrs["id"]
    title = attrs["title"]
    author = attrs["author"]
    tags = attrs["tags"] || []
    links = attrs["links"] || []
    class = attrs["class"] || "durable"
    body = attrs["body"] || ""

    extra_meta =
      attrs
      |> Map.drop(~w(id title author tags links class body created updated))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.sort_by(fn {k, _} -> k end)

    keyword_lines =
      [
        if(title, do: "#+TITLE: #{title}"),
        if(author, do: "#+AUTHOR: #{author}"),
        if(tags != [], do: "#+FILETAGS: #{format_filetags(tags)}")
      ]
      |> Enum.reject(&is_nil/1)

    drawer_lines =
      [
        ":PROPERTIES:",
        if(id, do: ":ID: #{id}"),
        if(links != [], do: ":LINKS: #{Enum.join(links, " ")}"),
        ":CLASS: #{class}"
      ] ++
        Enum.map(extra_meta, fn {k, v} -> ":#{drawer_key(k)}: #{format_drawer_value(v)}" end) ++
        [":END:"]

    drawer_lines = Enum.reject(drawer_lines, &is_nil/1)

    preamble = Enum.join(keyword_lines ++ drawer_lines, "\n")

    body_part =
      cond do
        body == "" -> ""
        true -> "\n\n" <> String.trim_leading(body)
      end

    String.trim_trailing(preamble <> body_part) <> "\n"
  end

  @doc """
  Applies `attrs` to existing org `content` by mutating only the affected
  lines. Returns the updated content.

  Behavior per attribute:

  - `title`/`author`: replaces the existing `#+TITLE:`/`#+AUTHOR:` line
    in-place (preserves the user's casing of the keyword), or inserts a
    new one near the top if absent.
  - `tags`: replaces the existing `#+FILETAGS:` line (or inserts one);
    `#+TAGS:` is also recognised on read but write canonically uses
    `#+FILETAGS`.
  - `links`/`class`/`id` and arbitrary extras: written into the file-level
    `:PROPERTIES:` drawer (one before the first headline). The drawer
    is created if missing.
  - `body`: spliced via `Egghead.RecordStore` — `splice_metadata/2`
    operates on the metadata layer only.

  The sentinel `:remove` deletes that key — the corresponding keyword
  line or drawer entry is dropped. Nil values are no-ops (preserves
  existing).
  """
  @spec splice_metadata(String.t(), map()) :: String.t()
  def splice_metadata(content, attrs) when is_map(attrs) do
    content
    |> splice_keyword("TITLE", attrs["title"])
    |> splice_keyword("AUTHOR", attrs["author"])
    |> splice_filetags(attrs["tags"])
    |> splice_drawer_entries(attrs)
  end

  # --- Keyword line splicing ---

  # Find the first matching `#+KEY:` line (case-insensitive) and replace
  # its value, preserving the user's casing of the keyword. If no line
  # exists, insert a new one before any other content (so the keyword
  # block stays at the top).
  defp splice_keyword(content, _key, nil), do: content

  defp splice_keyword(content, key, :remove) do
    pattern = ~r/^([ \t]*)#\+#{key}:[ \t]*[^\n]*\n?/im
    Regex.replace(pattern, content, "", global: false)
  end

  defp splice_keyword(content, key, value) when is_binary(value) do
    pattern = ~r/^([ \t]*)(#\+)(#{key})(:[ \t]*)([^\n]*)/im

    if Regex.match?(pattern, content) do
      Regex.replace(pattern, content, "\\1\\2\\3\\4#{escape_replacement(value)}", global: false)
    else
      insert_keyword_at_top(content, "#+#{key}: #{value}")
    end
  end

  defp splice_keyword(content, key, value), do: splice_keyword(content, key, to_string(value))

  defp splice_filetags(content, nil), do: content
  defp splice_filetags(content, []), do: splice_keyword(content, "FILETAGS", :remove)

  defp splice_filetags(content, tags) when is_list(tags) do
    formatted = format_filetags(tags)
    # Prefer existing #+FILETAGS but fall back to #+TAGS if that's what the
    # user used.
    cond do
      Regex.match?(~r/^[ \t]*#\+FILETAGS:/im, content) ->
        splice_keyword(content, "FILETAGS", formatted)

      Regex.match?(~r/^[ \t]*#\+TAGS:/im, content) ->
        splice_keyword(content, "TAGS", formatted)

      true ->
        insert_keyword_at_top(content, "#+FILETAGS: #{formatted}")
    end
  end

  # Insert a new keyword line at the top, after any existing keyword/comment
  # block but before any other content (drawers, headlines, paragraphs).
  defp insert_keyword_at_top(content, line) do
    lines = String.split(content, "\n")
    {prefix, rest} = take_keyword_prefix(lines, [])
    # Append the new line to the end of the existing keyword run so multiple
    # inserted-from-empty keywords stay together at the top in insertion order.
    Enum.join(prefix ++ [line | rest], "\n")
  end

  defp take_keyword_prefix([], acc), do: {Enum.reverse(acc), []}

  defp take_keyword_prefix([line | rest], acc) do
    cond do
      Regex.match?(~r/^[ \t]*#\+\w+:/, line) -> take_keyword_prefix(rest, [line | acc])
      Regex.match?(~r/^[ \t]*#[^+]/, line) -> take_keyword_prefix(rest, [line | acc])
      true -> {Enum.reverse(acc), [line | rest]}
    end
  end

  # --- Properties drawer splicing ---

  defp splice_drawer_entries(content, attrs) do
    extras =
      attrs
      |> Map.drop(~w(id title author tags links class body created updated))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    drawer_updates =
      [
        {"ID", attrs["id"]},
        {"LINKS", attrs["links"]},
        {"CLASS", attrs["class"]}
      ] ++ Enum.map(extras, fn {k, v} -> {drawer_key(k), v} end)

    drawer_updates =
      Enum.reject(drawer_updates, fn
        {_, nil} -> true
        {k, _} when k not in ["ID", "LINKS", "CLASS"] -> false
        _ -> false
      end)

    Enum.reduce(drawer_updates, content, fn {key, value}, acc ->
      splice_drawer_entry(acc, key, value)
    end)
  end

  defp splice_drawer_entry(content, _key, nil), do: content

  defp splice_drawer_entry(content, key, :remove) do
    case find_file_drawer(content) do
      {:ok, before, drawer, after_drawer} ->
        new_drawer = drop_drawer_line(drawer, key)

        if drawer_empty?(new_drawer),
          do: before <> after_drawer,
          else: before <> new_drawer <> after_drawer

      :none ->
        content
    end
  end

  defp splice_drawer_entry(content, key, value) do
    formatted = format_drawer_value(value)

    case find_file_drawer(content) do
      {:ok, before, drawer, after_drawer} ->
        new_drawer = upsert_drawer_line(drawer, key, formatted)
        before <> new_drawer <> after_drawer

      :none ->
        new_drawer = ":PROPERTIES:\n:#{key}: #{formatted}\n:END:\n"
        insert_drawer(content, new_drawer)
    end
  end

  # Locate the file-level :PROPERTIES: drawer — the first one that appears
  # before any headline. Returns `{:ok, before, drawer, after}` where
  # concatenating the three pieces yields the original content.
  defp find_file_drawer(content) do
    pattern = ~r/(?:^|\n)([ \t]*:PROPERTIES:[ \t]*\n.*?:END:[ \t]*\n?)/s

    case Regex.run(pattern, content, return: :index) do
      [{full_start, full_len}, {drawer_start, drawer_len}] ->
        # If a `*`-headline appears before this drawer, the drawer belongs
        # to that subtree, not the file. Skip it.
        before_text = binary_part(content, 0, drawer_start)

        if Regex.match?(~r/(^|\n)\*+ /, before_text) do
          :none
        else
          before = binary_part(content, 0, drawer_start)
          drawer = binary_part(content, drawer_start, drawer_len)

          after_drawer =
            binary_part(
              content,
              full_start + full_len,
              byte_size(content) - (full_start + full_len)
            )

          {:ok, before, drawer, after_drawer}
        end

      _ ->
        :none
    end
  end

  # Insert a new file-level drawer after the keyword/comment prefix and
  # before any other content.
  defp insert_drawer(content, drawer) do
    lines = String.split(content, "\n")
    {prefix, rest} = take_keyword_prefix(lines, [])

    prefix_str =
      case prefix do
        [] -> ""
        list -> Enum.join(list, "\n") <> "\n"
      end

    rest_str = Enum.join(rest, "\n")

    cond do
      prefix_str == "" -> drawer <> rest_str
      true -> prefix_str <> drawer <> rest_str
    end
  end

  defp upsert_drawer_line(drawer, key, value) do
    pattern = ~r/^([ \t]*):#{key}:[ \t]*[^\n]*\n?/im

    if Regex.match?(pattern, drawer) do
      Regex.replace(pattern, drawer, "\\1:#{key}: #{escape_replacement(value)}\n", global: false)
    else
      # Insert before the :END: line.
      Regex.replace(
        ~r/([ \t]*):END:/,
        drawer,
        "\\1:#{key}: #{escape_replacement(value)}\n\\1:END:",
        global: false
      )
    end
  end

  defp drop_drawer_line(drawer, key) do
    Regex.replace(~r/^([ \t]*):#{key}:[ \t]*[^\n]*\n?/im, drawer, "", global: false)
  end

  # A drawer with no entries between :PROPERTIES: and :END: is empty.
  defp drawer_empty?(drawer) do
    inner = Regex.replace(~r/^[ \t]*:PROPERTIES:[ \t]*\n/, drawer, "", global: false)
    inner = Regex.replace(~r/[ \t]*:END:[ \t]*\n?/, inner, "", global: false)
    String.trim(inner) == ""
  end

  # --- Formatting helpers ---

  @doc """
  Formats a tag list as a `#+FILETAGS:` value.

  Org's canonical FILETAGS form is `:foo:bar:baz:` (colon-delimited with
  leading and trailing colons). Empty list returns `""`.
  """
  @spec format_filetags([String.t()]) :: String.t()
  def format_filetags([]), do: ""

  def format_filetags(tags) when is_list(tags) do
    ":" <> Enum.join(tags, ":") <> ":"
  end

  defp format_drawer_value(value) when is_list(value), do: Enum.join(value, " ")
  defp format_drawer_value(value) when is_binary(value), do: value
  defp format_drawer_value(value), do: to_string(value)

  defp drawer_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.upcase()
  defp drawer_key(key) when is_binary(key), do: String.upcase(key)

  # Regex.replace interprets `\` and `\N` in the replacement; escape them so
  # values containing backslashes are written literally.
  defp escape_replacement(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
  end
end
