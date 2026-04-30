defmodule Egghead.Record.Parser do
  @moduledoc """
  Parses Markdown (YAML frontmatter) and org-mode (property drawer) files
  into `Egghead.Record` structs.

  Format detection: files starting with `---` are treated as Markdown with
  YAML frontmatter. Files starting with `:PROPERTIES:` are treated as org-mode.
  """

  alias Egghead.Record
  alias Egghead.Record.AST
  alias Egghead.Record.OrgParser

  @doc """
  Detects the format of a record file from its content.

  Returns `:markdown` if the content begins with YAML frontmatter (`---`),
  `:org` if it begins with org-mode markers (a property drawer, a
  `#+`-keyword, or a top-level `*`-headline), or `:unknown` otherwise.

  Pass `source_path:` in `opts` to use the filename extension as a tiebreaker
  for content that has no obvious format markers — `.org` wins over the
  default markdown fallback.
  """
  @spec detect_format(String.t(), keyword()) :: :markdown | :org | :unknown
  def detect_format(content, opts \\ []) do
    trimmed = String.trim_leading(content)
    first_line = first_nonblank_line(trimmed)

    cond do
      String.starts_with?(trimmed, "---") ->
        :markdown

      String.starts_with?(trimmed, ":PROPERTIES:") ->
        :org

      # File-level org keywords (`#+TITLE:`, `#+AUTHOR:`, etc.) are the
      # most common org pattern and don't require a property drawer.
      Regex.match?(~r/^#\+\w+:/, first_line) ->
        :org

      # Top-level org headlines (`* Heading`).
      Regex.match?(~r/^\*+\s/, first_line) ->
        :org

      true ->
        case Keyword.get(opts, :source_path) do
          path when is_binary(path) ->
            case Path.extname(path) do
              ".org" -> :org
              ".md" -> :markdown
              _ -> :unknown
            end

          _ ->
            :unknown
        end
    end
  end

  defp first_nonblank_line(content) do
    content
    |> String.split("\n")
    |> Enum.find("", &(String.trim(&1) != ""))
  end

  @doc """
  Parses file content into a `Record` struct. Detects format automatically.

  Plain markdown files without frontmatter are accepted — metadata is derived
  from the opts (`:source_path` for id/created, `:default_author` for author).

  Returns `{:ok, record}` or `{:error, reason}`.
  """
  @spec parse(String.t(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def parse(content, opts \\ []) do
    case detect_format(content, opts) do
      :markdown -> parse_markdown(content, opts)
      :org -> parse_org(content, opts)
      :unknown -> parse_markdown(content, opts)
    end
  end

  @doc """
  Parses a Markdown file with YAML frontmatter into a `Record` struct.
  """
  @spec parse_markdown(String.t(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def parse_markdown(content, opts \\ []) do
    case split_frontmatter(content) do
      {:ok, yaml_str, body} ->
        case YamlElixir.read_from_string(yaml_str) do
          {:ok, meta} when is_map(meta) ->
            record = build_record(meta, body, :markdown, opts)
            {:ok, record}

          {:ok, _} ->
            {:error, :invalid_frontmatter}

          {:error, reason} ->
            {:error, {:yaml_parse_error, reason}}
        end

      :error ->
        # No frontmatter — treat entire content as body, derive metadata
        body = String.trim(content)
        record = build_record(%{}, body, :markdown, opts)
        {:ok, record}
    end
  end

  @doc """
  Parses an org-mode file into a `Record` struct.

  Org records have no separate "frontmatter" concept — `#+`-keywords and
  property drawers are part of the document. This parser extracts metadata
  by scanning the AST for `#+TITLE`/`#+AUTHOR`/`#+FILETAGS`/`#+CLASS` etc.
  and any property drawer that appears before the first headline, but the
  returned `record.body` is the **entire input content**, byte-faithful.

  Renderers and editors operate on `record.body` directly so what's on disk
  is what the user sees and edits.
  """
  @spec parse_org(String.t(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def parse_org(content, opts \\ []) do
    body = String.trim_trailing(content)
    meta = extract_org_metadata(body)
    record = build_record(meta, body, :org, opts)
    {:ok, record}
  end

  @doc """
  Extracts file-level metadata from raw org content.

  Walks the OrgParser AST and collects:

  - All `#+KEY:` keyword values (downcased keys), with the last value winning
    if a key appears multiple times.
  - Properties from the first property drawer that appears before any headline
    (treated as file-level properties; drawers attached to headlines stay
    headline-local and are not extracted here).

  Known keyword aliases are normalized: `#+FILETAGS` and `#+TAGS` both map to
  `tags` (parsed as space- or colon-separated when given as a string), and
  the property drawer's `:ID:` maps to `id`. Returns a flat string-keyed map
  ready to feed `build_record/4`.
  """
  @spec extract_org_metadata(String.t()) :: map()
  def extract_org_metadata(content) do
    {:ok, ast} = Egghead.Record.OrgParser.parse(content)

    keywords = collect_org_keywords(ast)
    drawer_props = collect_first_file_drawer(ast)

    keywords
    |> Map.merge(drawer_props)
    |> normalize_org_metadata()
  end

  defp collect_org_keywords(ast) do
    Enum.reduce(ast, %{}, fn
      {:keyword, %{key: key, value: value}, _}, acc ->
        Map.put(acc, String.downcase(key), value)

      _, acc ->
        acc
    end)
  end

  # Only the FIRST property drawer encountered before any headline is treated
  # as file-level. Drawers attached to headlines belong to that subtree and
  # are not promoted to record metadata.
  defp collect_first_file_drawer(ast) do
    Enum.reduce_while(ast, %{}, fn
      {:property_drawer, _, props}, _acc ->
        map = Map.new(props, fn {k, v} -> {String.downcase(k), v} end)
        {:halt, map}

      {:headline, _, _}, _acc ->
        {:halt, %{}}

      _, acc ->
        {:cont, acc}
    end)
  end

  # Map org-flavored keys to record-frontmatter keys + parse list-y values.
  # Org `#+FILETAGS: :foo:bar:` and `#+TAGS: foo bar` both feed `tags`;
  # property drawers can use `:TAGS:` and `:LINKS:` with space-separated
  # values for parity with the existing record convention.
  defp normalize_org_metadata(meta) do
    meta
    |> rename_key("filetags", "tags")
    |> Map.update("tags", [], &parse_org_tags_value/1)
    |> Map.update("links", [], &parse_space_separated/1)
  end

  defp rename_key(map, from, to) do
    case Map.pop(map, from) do
      {nil, m} ->
        m

      {value, m} ->
        # Caller-set canonical key wins if both are present.
        if Map.has_key?(m, to), do: m, else: Map.put(m, to, value)
    end
  end

  # Org tags can be `:foo:bar:` (FILETAGS form), `foo bar` (TAGS form),
  # or already a list (drawer parsing returned a string we treat as
  # space-separated). Normalize all to a list of strings.
  defp parse_org_tags_value(nil), do: []
  defp parse_org_tags_value([]), do: []
  defp parse_org_tags_value(list) when is_list(list), do: Enum.map(list, &to_string/1)

  defp parse_org_tags_value(str) when is_binary(str) do
    trimmed = String.trim(str)

    cond do
      trimmed == "" -> []
      String.starts_with?(trimmed, ":") -> trimmed |> String.split(":", trim: true)
      true -> parse_space_separated(trimmed)
    end
  end

  # --- Private helpers ---

  @doc """
  Splits a markdown file into YAML frontmatter and body.

  Returns `{:ok, yaml_string, body}` where `yaml_string` is the YAML
  content (without `---` delimiters) and `body` is the trimmed content
  after the closing `---`. Returns `:error` if no valid frontmatter found.
  """
  @spec split_frontmatter(String.t()) :: {:ok, String.t(), String.t()} | :error
  def split_frontmatter(content) do
    trimmed = String.trim_leading(content)

    case String.split(trimmed, ~r/\n---\s*\n/, parts: 2) do
      ["---" <> yaml_str, body] ->
        {:ok, String.trim(yaml_str), String.trim(body)}

      _ ->
        # Handle frontmatter with no body after it
        case String.split(trimmed, ~r/\n---\s*\z/, parts: 2) do
          ["---" <> yaml_str, ""] ->
            {:ok, String.trim(yaml_str), ""}

          ["---" <> yaml_str] ->
            if String.contains?(yaml_str, "\n---") do
              :error
            else
              # Single frontmatter block with no closing ---
              :error
            end

          _ ->
            :error
        end
    end
  end

  @doc """
  Splits a file into the raw frontmatter block (including `---` delimiters)
  and the raw body after it. Unlike `split_frontmatter/1`, nothing is trimmed
  or stripped — both parts can be reassembled into the original file.

  Returns `{:ok, raw_frontmatter, raw_body}` or `:error`.
  """
  @spec split_raw(String.t()) :: {:ok, String.t(), String.t()} | :error
  def split_raw(content) do
    case Regex.split(~r/\n---[ \t]*\n/, content, parts: 2, include_captures: true) do
      [front, sep, body] ->
        if String.starts_with?(String.trim_leading(front), "---") do
          {:ok, front <> sep, body}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp parse_space_separated(nil), do: []
  defp parse_space_separated([]), do: []
  defp parse_space_separated(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp parse_space_separated(""), do: []

  defp parse_space_separated(str) when is_binary(str) do
    str |> String.split(~r/\s+/, trim: true)
  end

  @doc """
  Extracts wikilinks from body text.

  Supports:
  - `[[target]]`
  - `[[target|display text]]`
  - `[[target#fragment]]`
  - `[[target#fragment|display text]]`

  Returns a list of `%{target: id, display: string | nil, fragment: string | nil}`.
  """
  @spec extract_wikilinks(String.t()) :: [Record.wikilink()]
  def extract_wikilinks(body) do
    ~r/\[\[([^\]\|#]+)(?:#([^\]\|]+))?(?:\|([^\]]+))?\]\]/
    |> Regex.scan(body)
    |> Enum.map(fn match ->
      target = Enum.at(match, 1, "") |> String.trim()
      fragment = Enum.at(match, 2) |> nil_if_empty()
      display = Enum.at(match, 3) |> nil_if_empty()

      %{target: target, display: display, fragment: fragment}
    end)
  end

  defp nil_if_empty(nil), do: nil
  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: String.trim(s)

  defp build_record(meta, body, :markdown, opts) do
    source_path = Keyword.get(opts, :source_path)
    records_dir = Keyword.get(opts, :records_dir)
    {ast, wikilinks, ast_title, outline} = parse_markdown_ast(body)

    title = to_nil_string(meta["title"]) || ast_title

    %Record{
      id: to_string(meta["id"] || derive_id(source_path, records_dir)),
      title: title,
      created: normalize_timestamp(meta["created"]) || derive_created(source_path),
      updated: derive_updated(source_path),
      author: to_nil_string(meta["author"]) || derive_author(source_path),
      tags: normalize_list(meta["tags"]),
      links: normalize_list(meta["links"]),
      wikilinks: wikilinks,
      class: Record.parse_class(meta["class"]),
      meta: extract_extra_meta(meta),
      body: body,
      ast: ast,
      outline: outline,
      format: :markdown,
      source_path: source_path
    }
  end

  defp build_record(meta, body, :org, opts) do
    source_path = Keyword.get(opts, :source_path)
    records_dir = Keyword.get(opts, :records_dir)
    {ast, org_wikilinks, org_title, outline} = parse_org_ast(body)

    title = to_nil_string(meta["title"]) || org_title

    %Record{
      id: to_string(meta["id"] || derive_id(source_path, records_dir)),
      title: title,
      created: normalize_timestamp(meta["created"]) || derive_created(source_path),
      updated: derive_updated(source_path),
      author: to_nil_string(meta["author"]) || derive_author(source_path),
      tags: normalize_list(meta["tags"]),
      links: normalize_list(meta["links"]),
      wikilinks: org_wikilinks,
      class: Record.parse_class(meta["class"]),
      meta: extract_extra_meta(meta),
      body: body,
      ast: ast,
      outline: outline,
      format: :org,
      source_path: source_path
    }
  end

  defp parse_org_ast(body) do
    case OrgParser.parse(body) do
      {:ok, ast} ->
        wikilinks = OrgParser.extract_links(ast)
        title = OrgParser.extract_title(ast)
        outline = OrgParser.extract_outline(ast)
        {ast, wikilinks, title, outline}

      _ ->
        # Fall back to regex
        {nil, extract_wikilinks(body), extract_heading(body), []}
    end
  end

  defp parse_markdown_ast(body) do
    case AST.parse_markdown(body) do
      {:ok, ast} ->
        wikilinks = AST.extract_wikilinks(ast)
        title = AST.extract_title(ast)
        outline = AST.extract_outline(ast)
        {ast, wikilinks, title, outline}

      {:error, _} ->
        # Fall back to regex if Earmark fails
        {nil, extract_wikilinks(body), extract_heading(body), []}
    end
  end

  defp derive_id(nil, _records_dir), do: "unknown"

  defp derive_id(path, records_dir) do
    if records_dir do
      # Expand both to resolve symlinks (e.g. /tmp -> /private/var on macOS)
      Path.expand(path)
      |> Path.relative_to(Path.expand(records_dir))
      |> Path.rootname()
    else
      path |> Path.basename() |> Path.rootname()
    end
  end

  defp derive_author(nil), do: nil

  defp derive_author(path) do
    case File.stat(path) do
      {:ok, %{uid: uid}} ->
        case :os.type() do
          {:unix, _} ->
            uid
            |> to_string()
            |> then(&:os.cmd(~c"id -un #{&1}"))
            |> to_string()
            |> String.trim()
            |> case do
              "" -> nil
              name -> name
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp derive_created(nil), do: nil

  defp derive_created(path) do
    # Use birthtime on macOS (real creation time), fall back to ctime
    case :os.type() do
      {:unix, :darwin} ->
        path
        |> to_charlist()
        |> then(&:os.cmd(~c"stat -f %B #{&1}"))
        |> to_string()
        |> String.trim()
        |> case do
          "" ->
            nil

          ts_str ->
            case Integer.parse(ts_str) do
              {ts, _} -> ts |> DateTime.from_unix!() |> DateTime.to_iso8601()
              :error -> nil
            end
        end

      _ ->
        # Linux/other: ctime is the best we have (inode change time)
        case File.stat(path, time: :posix) do
          {:ok, %{ctime: ctime}} ->
            ctime |> DateTime.from_unix!() |> DateTime.to_iso8601()

          _ ->
            nil
        end
    end
  end

  @doc """
  Returns the ISO8601 modification timestamp of `path`, or `nil` if
  the file can't be stat'd. The hydrated record's `updated` field is
  populated from this, so callers that want to know "has this file
  changed since we last read it?" can compare against `record.updated`.
  """
  @spec derive_updated(String.t() | nil) :: String.t() | nil
  def derive_updated(nil), do: nil

  def derive_updated(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        mtime |> DateTime.from_unix!() |> DateTime.to_iso8601()

      _ ->
        nil
    end
  end

  @doc """
  Returns a cheap invalidation fingerprint for `path` — `{mtime, size}`
  — or `nil` if the file can't be stat'd. Mtime alone is insufficient
  on filesystems with second-granularity timestamps (two rewrites in
  the same second look identical); pairing with size catches nearly
  all in-second edits, which is what content caches need.
  """
  @spec file_fingerprint(String.t() | nil) :: {integer(), non_neg_integer()} | nil
  def file_fingerprint(nil), do: nil

  def file_fingerprint(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      _ -> nil
    end
  end

  defp extract_heading(body) do
    body
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^#\s+(.+)$/, String.trim(line)) do
        [_, title] -> String.trim(title)
        _ -> nil
      end
    end)
  end

  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(val) when is_binary(val), do: parse_space_separated(val)
  defp normalize_list(_), do: []

  defp normalize_timestamp(nil), do: nil
  defp normalize_timestamp(%Date{} = d), do: Date.to_iso8601(d)
  defp normalize_timestamp(val) when is_binary(val), do: val
  defp normalize_timestamp(val), do: to_string(val)

  defp extract_extra_meta(meta) when is_map(meta) do
    meta
    |> Map.drop(Record.known_keys())
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp extract_extra_meta(_), do: %{}

  defp to_nil_string(nil), do: nil
  defp to_nil_string(val), do: to_string(val)
end
