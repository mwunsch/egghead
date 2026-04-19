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

  Returns `:markdown` if the content starts with `---`,
  `:org` if it starts with `:PROPERTIES:`, or `:unknown` otherwise.
  """
  @spec detect_format(String.t()) :: :markdown | :org | :unknown
  def detect_format(content) do
    trimmed = String.trim_leading(content)

    cond do
      String.starts_with?(trimmed, "---") -> :markdown
      String.starts_with?(trimmed, ":PROPERTIES:") -> :org
      true -> :unknown
    end
  end

  @doc """
  Parses file content into a `Record` struct. Detects format automatically.

  Plain markdown files without frontmatter are accepted — metadata is derived
  from the opts (`:source_path` for id/created, `:default_author` for author).

  Returns `{:ok, record}` or `{:error, reason}`.
  """
  @spec parse(String.t(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def parse(content, opts \\ []) do
    case detect_format(content) do
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
  Parses an org-mode file with a property drawer into a `Record` struct.
  """
  @spec parse_org(String.t(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def parse_org(content, opts \\ []) do
    case split_property_drawer(content) do
      {:ok, props, body} ->
        org_title = extract_org_title(body)
        meta = normalize_org_props(props) |> Map.put("title", org_title)
        record = build_record(meta, extract_org_body(body), :org, opts)
        {:ok, record}

      :error ->
        {:error, :no_property_drawer}
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

  defp split_property_drawer(content) do
    trimmed = String.trim_leading(content)

    if String.starts_with?(trimmed, ":PROPERTIES:") do
      case String.split(trimmed, ":END:", parts: 2) do
        [drawer, rest] ->
          props = parse_drawer_properties(drawer)
          {:ok, props, String.trim(rest)}

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp parse_drawer_properties(drawer) do
    drawer
    |> String.split("\n")
    |> Enum.reject(&(&1 =~ ~r/^\s*:PROPERTIES:\s*$/))
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^\s*:(\w+):\s*(.*)$/, String.trim(line)) do
        [_, key, value] ->
          Map.put(acc, String.downcase(key), String.trim(value))

        _ ->
          acc
      end
    end)
  end

  defp normalize_org_props(props) do
    # Start with all properties (preserves arbitrary keys)
    # Then override known keys that need special handling
    props
    |> Map.put("tags", parse_space_separated(Map.get(props, "tags", "")))
    |> Map.put("links", parse_space_separated(Map.get(props, "links", "")))
  end

  defp parse_space_separated(nil), do: []
  defp parse_space_separated(""), do: []

  defp parse_space_separated(str) do
    str |> String.split(~r/\s+/, trim: true)
  end

  defp extract_org_title(text) do
    text
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s*#\+TITLE:\s*(.+)$/i, line) do
        [_, title] -> String.trim(title)
        _ -> nil
      end
    end)
  end

  defp extract_org_body(text) do
    lines = String.split(text, "\n")

    lines
    |> Enum.reject(&String.match?(&1, ~r/^\s*#\+TITLE:/i))
    |> Enum.join("\n")
    |> String.trim()
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
