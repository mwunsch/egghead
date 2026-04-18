defmodule Egghead.RecordStore do
  @moduledoc """
  GenServer that manages the record store.

  Watches a configurable records directory on the filesystem, delegates
  all queries to `Egghead.Index` (SQLite-backed), and handles file
  creation and filesystem events.

  The Index stores lightweight metadata. `get_record/2` hydrates the
  full record (body, AST, outline) from disk on each call — files are
  the source of truth.

  ## State

  The GenServer state is an explicit `%Egghead.RecordStore.State{}` struct
  containing the records directory path, watcher pid, and index server ref.
  """

  use GenServer
  require Logger

  alias Egghead.Index
  alias Egghead.Record
  alias Egghead.Record.Parser

  # --- State struct ---

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            records_dir: String.t(),
            skills_dir: String.t() | nil,
            watcher_pid: pid() | nil,
            index: GenServer.server()
          }

    defstruct records_dir: nil, skills_dir: nil, watcher_pid: nil, index: Index
  end

  # --- Public API ---

  @doc """
  Starts the RecordStore GenServer.

  ## Options

    * `:records_dir` — path to the directory containing record files (required)
    * `:watch` — whether to watch the filesystem for changes (default: `true`)
    * `:index` — the Index server to use (default: `Egghead.Index`)
    * `:name` — GenServer registration name (defaults to `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Creates a new record by writing a Markdown file to the records directory.

  Returns `{:ok, record}` or `{:error, reason}`.
  """
  @spec create_record(GenServer.server(), map()) :: {:ok, Record.t()} | {:error, term()}
  def create_record(server \\ __MODULE__, attrs) do
    Egghead.Node.call(server, {:create_record, attrs})
  end

  @doc """
  Updates an existing record by overwriting its Markdown file.

  Returns `{:ok, record}` or `{:error, :not_found}`.
  """
  @spec update_record(GenServer.server(), String.t(), map()) ::
          {:ok, Record.t()} | {:error, term()}
  def update_record(server \\ __MODULE__, id, attrs) do
    Egghead.Node.call(server, {:update_record, id, attrs})
  end

  @doc """
  Gets a record by its id, hydrated with full body and AST from disk.

  Returns `{:ok, record}` or `{:error, :not_found}`.
  """
  @spec get_record(GenServer.server(), String.t()) :: {:ok, Record.t()} | {:error, :not_found}
  def get_record(server \\ __MODULE__, id) do
    Egghead.Node.call(server, {:get_record, id})
  end

  @doc """
  Lists all records in the store (lightweight, no body/ast).
  """
  @spec list_records(GenServer.server()) :: [Record.t()]
  def list_records(server \\ __MODULE__) do
    Egghead.Node.call(server, :list_records)
  end

  @doc """
  Searches for records matching the given tag.
  """
  @spec search_by_tag(GenServer.server(), String.t()) :: [Record.t()]
  def search_by_tag(server \\ __MODULE__, tag) do
    Egghead.Node.call(server, {:search_by_tag, tag})
  end

  @doc """
  Searches for records matching the given class.
  """
  @spec search_by_class(GenServer.server(), Record.class()) :: [Record.t()]
  def search_by_class(server \\ __MODULE__, class) do
    Egghead.Node.call(server, {:search_by_class, class})
  end

  @doc """
  Finds linked records starting from the given id, traversing `depth` levels.
  """
  @spec find_links(GenServer.server(), String.t(), non_neg_integer()) :: [Record.t()]
  def find_links(server \\ __MODULE__, id, depth \\ 1) do
    Egghead.Node.call(server, {:find_links, id, depth})
  end

  @doc """
  Finds records that link TO the given id (reverse graph).
  """
  @spec find_backlinks(GenServer.server(), String.t()) :: [Record.t()]
  def find_backlinks(server \\ __MODULE__, id) do
    Egghead.Node.call(server, {:find_backlinks, id})
  end

  @doc """
  Full-text search across record titles and bodies.
  """
  @spec search(GenServer.server(), String.t(), keyword()) :: [Record.t()]
  def search(server \\ __MODULE__, query, opts \\ []) do
    Egghead.Node.call(server, {:search, query, opts})
  end

  @doc """
  Returns recently modified or created records.
  """
  @spec recent(GenServer.server(), keyword()) :: [Record.t()]
  def recent(server \\ __MODULE__, opts \\ []) do
    Egghead.Node.call(server, {:recent, opts})
  end

  @doc """
  Reloads all records from the filesystem into the index.
  """
  @spec reload(GenServer.server()) :: :ok
  def reload(server \\ __MODULE__) do
    Egghead.Node.call(server, :reload, :infinity)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    records_dir = Keyword.fetch!(opts, :records_dir)
    File.mkdir_p!(records_dir)
    # Resolve symlinks so file watcher paths match (e.g. /tmp -> /private/tmp on macOS)
    records_dir = records_dir |> Path.expand() |> resolve_symlinks()

    skills_dir =
      case Keyword.get(opts, :skills_dir) do
        nil -> nil
        dir -> dir |> Path.expand() |> resolve_symlinks()
      end

    index = Keyword.get(opts, :index, Index)
    watch? = Keyword.get(opts, :watch, true)

    watch_dirs =
      [records_dir, skills_dir]
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&File.dir?/1)

    watcher_pid =
      if watch? do
        case FileSystem.start_link(dirs: watch_dirs) do
          {:ok, pid} ->
            FileSystem.subscribe(pid)
            pid

          {:error, _} ->
            nil
        end
      end

    state = %State{
      records_dir: records_dir,
      skills_dir: skills_dir,
      watcher_pid: watcher_pid,
      index: index
    }

    # Build the index from files
    Index.rebuild(index, records_dir)
    if skills_dir, do: scan_skills_dir(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:create_record, attrs}, _from, state) do
    id = Map.get(attrs, :id) || Map.get(attrs, "id") || generate_id()
    attrs = normalize_attrs(attrs, id)

    # Check if already exists in index
    case Index.get_record_meta(state.index, id) do
      {:ok, _} ->
        {:reply, {:error, :already_exists}, state}

      {:error, :not_found} ->
        content = render_markdown(attrs)
        filename = "#{id}.md"
        path = Path.join(state.records_dir, filename)

        if File.exists?(path) do
          {:reply, {:error, :already_exists}, state}
        else
          # Ensure intermediate directories exist (e.g. records/chat/)
          path |> Path.dirname() |> File.mkdir_p!()
          File.write!(path, content)

          case Parser.parse(content, source_path: path, records_dir: state.records_dir) do
            {:ok, record} ->
              Index.upsert_record(state.index, record)
              broadcast_record_change(record.id)
              {:reply, {:ok, record}, state}

            {:error, reason} ->
              File.rm(path)
              {:reply, {:error, reason}, state}
          end
        end
    end
  end

  def handle_call({:update_record, id, attrs}, _from, state) do
    case Index.get_record_meta(state.index, id) do
      {:ok, meta} ->
        path = meta.source_path

        case hydrate(path, state.records_dir) do
          {:ok, existing} ->
            normalized = normalize_attrs(attrs, id)

            content =
              if body_only_update?(normalized) do
                splice_body(path, normalized["body"])
              else
                merged = merge_record_attrs(existing, normalized)
                render_markdown(merged)
              end

            File.write!(path, content)

            case Parser.parse(content, source_path: path, records_dir: state.records_dir) do
              {:ok, record} ->
                Index.upsert_record(state.index, record)
                maybe_restart_agent(record)
                broadcast_record_change(record.id)
                {:reply, {:ok, record}, state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get_record, id}, _from, state) do
    case Index.get_record_meta(state.index, id) do
      {:ok, meta} ->
        # Preserve the id + class from the index rather than letting the
        # parser re-derive. Skills have normalized ids (e.g. "skills/foo"
        # from a SKILL.md at path `~/.agents/skills/foo/SKILL.md`) that
        # the parser would otherwise re-derive incorrectly.
        case hydrate(meta.source_path, state.records_dir) do
          {:ok, record} ->
            {:reply,
             {:ok, %{record | id: meta.id, class: Egghead.Record.parse_class(meta.class)}}, state}

          other ->
            {:reply, other, state}
        end

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_records, _from, state) do
    {:reply, Index.list_records(state.index), state}
  end

  def handle_call({:search_by_tag, tag}, _from, state) do
    {:reply, Index.search_by_tag(state.index, tag), state}
  end

  def handle_call({:search_by_class, class}, _from, state) do
    {:reply, Index.search_by_class(state.index, class), state}
  end

  def handle_call({:find_links, id, depth}, _from, state) do
    {:reply, Index.find_links(state.index, id, depth), state}
  end

  def handle_call({:find_backlinks, id}, _from, state) do
    {:reply, Index.find_backlinks(state.index, id), state}
  end

  def handle_call({:search, query, opts}, _from, state) do
    {:reply, Index.search(state.index, query, opts), state}
  end

  def handle_call({:recent, opts}, _from, state) do
    {:reply, Index.recent(state.index, opts), state}
  end

  def handle_call(:reload, _from, state) do
    Index.rebuild(state.index, state.records_dir)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    cond do
      in_dir?(path, state.skills_dir) and skill_manifest?(path) ->
        handle_skill_change(state, path)

      in_dir?(path, state.records_dir) and record_file?(path) ->
        handle_file_change(state, path)

      true ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    {:noreply, state}
  end

  # --- Private helpers ---

  defp handle_file_change(state, path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Parser.parse(content, source_path: path, records_dir: state.records_dir) do
            {:ok, record} ->
              record = maybe_promote_to_skill(record)
              Index.upsert_record(state.index, record)
              maybe_restart_agent(record)
              broadcast_record_change(record.id)

            {:error, reason} ->
              Logger.warning("Skipping #{path}: #{inspect(reason)}")
          end

        {:error, _} ->
          :skip
      end
    else
      Index.delete_by_path(state.index, path)
      broadcast_record_change(nil)
      sync_agents_async()
    end
  end

  # Source 3 of the skill vocabulary: records in records_dir matching
  # the `skills/<name>[/SKILL]` path convention are auto-classified to
  # `class: skill` via `Egghead.Skill.auto_classify/1`. Same promotion
  # is applied by `Egghead.Index.do_rebuild/2` so initial scans behave
  # identically to live file events.
  defp maybe_promote_to_skill(record), do: Egghead.Skill.auto_classify(record)

  # Skills live outside the record store (SKILLS_DIR) but are exposed
  # to agents as `class: skill` virtual records via the same index.
  # Id is derived from the path relative to skills_dir, prefixed with
  # `skills/` and stripped of the conventional `/SKILL` suffix.
  defp handle_skill_change(state, path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Parser.parse(content, source_path: path) do
            {:ok, record} ->
              skill_record = %{
                record
                | id: skill_id_for(path, state.skills_dir),
                  class: :skill
              }

              Index.upsert_record(state.index, skill_record)
              broadcast_record_change(skill_record.id)

            {:error, reason} ->
              Logger.warning("Skipping skill #{path}: #{inspect(reason)}")
          end

        {:error, _} ->
          :skip
      end
    else
      Index.delete_by_path(state.index, path)
      broadcast_record_change(nil)
    end
  end

  defp in_dir?(_path, nil), do: false

  defp in_dir?(path, dir) do
    expanded_path = Path.expand(path)
    expanded_dir = Path.expand(dir)
    String.starts_with?(expanded_path, expanded_dir <> "/") or expanded_path == expanded_dir
  end

  defp skill_id_for(path, skills_dir) do
    rel =
      path
      |> Path.expand()
      |> Path.relative_to(Path.expand(skills_dir))
      |> Path.rootname()

    name =
      cond do
        String.ends_with?(rel, "/SKILL") -> String.replace_suffix(rel, "/SKILL", "")
        true -> rel
      end

    "skills/" <> name
  end

  defp scan_skills_dir(%State{skills_dir: dir} = state) when is_binary(dir) do
    if File.dir?(dir) do
      # Only pick up files that match the Agent Skills convention —
      # `<skills_dir>/<name>/SKILL.md` (one skill per directory). Flat
      # README.md / CLAUDE.md / other helper docs in a skill dir are
      # ignored; they're reference material, not skill definitions.
      dir
      |> Path.join("*/SKILL.md")
      |> Path.wildcard()
      |> Enum.each(&handle_skill_change(state, &1))
    end
  end

  defp scan_skills_dir(_), do: :ok

  @doc "PubSub topic for record change notifications."
  def records_topic, do: "records:changes"

  defp broadcast_record_change(record_id) do
    if Process.whereis(Egghead.PubSub) do
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        records_topic(),
        {:record_changed, record_id}
      )
    end
  end

  defp maybe_restart_agent(%{class: :agent} = record) do
    if Process.whereis(Egghead.Agent.Supervisor) do
      Task.start(fn -> Egghead.Agent.Supervisor.start_agent(record) end)
    end
  end

  defp maybe_restart_agent(_), do: :ok

  defp sync_agents_async do
    if Process.whereis(Egghead.Agent.Supervisor) do
      Task.start(fn -> Egghead.Agent.Supervisor.sync_agents() end)
    end
  end

  # A skill manifest in SKILLS_DIR is specifically a `SKILL.md` file —
  # `README.md`, `CLAUDE.md`, and other helper docs in a skill dir are
  # reference material, not skill definitions.
  defp skill_manifest?(path), do: Path.basename(path) == "SKILL.md"

  defp record_file?(path) do
    ext = Path.extname(path)
    ext == ".md" or ext == ".org"
  end

  defp hydrate(nil, _records_dir), do: {:error, :not_found}

  defp hydrate(path, records_dir) do
    case File.read(path) do
      {:ok, content} ->
        case Parser.parse(content, source_path: path, records_dir: records_dir) do
          {:ok, record} -> {:ok, record}
          {:error, _} -> {:error, :parse_error}
        end

      {:error, _} ->
        {:error, :file_read_error}
    end
  end

  defp normalize_attrs(attrs, id) do
    attrs
    |> Enum.into(%{}, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
    |> Map.put("id", id)
  end

  # Merge caller-provided attrs onto existing record, keeping existing values
  # for any field the caller didn't provide.
  defp merge_record_attrs(existing, new_attrs) do
    known_fields = %{
      "id" => existing.id,
      "title" => existing.title,
      "created" => existing.created,
      "updated" => existing.updated,
      "author" => existing.author,
      "tags" => existing.tags,
      "links" => existing.links,
      "class" => to_string(existing.class),
      "body" => existing.body
    }

    # Start with all known fields from existing record
    base = known_fields

    # Add existing arbitrary meta fields
    base = Map.merge(base, existing.meta || %{})

    # Overlay with non-nil values from caller
    new_attrs
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(base)
  end

  # True when the only meaningful key in the attrs is "body" (plus "id"
  # which normalize_attrs always injects). Skips frontmatter re-rendering.
  defp body_only_update?(attrs) do
    meaningful = attrs |> Map.drop(["id"]) |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    match?([{"body", _}], meaningful)
  end

  # Replace just the body portion of a file, preserving the raw
  # frontmatter exactly as written on disk.
  defp splice_body(path, new_body) do
    raw = File.read!(path)

    case Parser.split_raw(raw) do
      {:ok, raw_frontmatter, _old_body} ->
        String.trim_trailing(raw_frontmatter <> (new_body || "")) <> "\n"

      :error ->
        # No frontmatter — just the body
        String.trim_trailing(new_body || "") <> "\n"
    end
  end

  @known_frontmatter_keys ~w(id created updated author tags links class)

  defp render_markdown(attrs) do
    # Known fields in a stable order
    known_lines =
      [
        "---",
        "id: #{attrs["id"]}",
        maybe_field("created", attrs["created"]),
        maybe_field("updated", attrs["updated"]),
        maybe_field("author", attrs["author"]),
        render_list("tags", attrs["tags"]),
        render_list("links", attrs["links"]),
        "class: #{attrs["class"] || "durable"}"
      ]

    # Arbitrary meta fields (anything not in known keys, not body/title)
    skip_keys = MapSet.new(@known_frontmatter_keys ++ ["body", "title"])

    meta_lines =
      attrs
      |> Enum.reject(fn {k, _v} -> MapSet.member?(skip_keys, k) end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> render_meta_field(k, v) end)

    frontmatter =
      (known_lines ++ meta_lines ++ ["---"])
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    title = attrs["title"]
    body = attrs["body"] || ""

    # Don't duplicate the heading if the body already starts with it
    body_has_heading =
      title != nil and String.starts_with?(String.trim(body), "# ")

    content =
      cond do
        body_has_heading ->
          "#{frontmatter}\n\n#{body}"

        title ->
          "#{frontmatter}\n\n# #{title}\n\n#{body}"

        true ->
          "#{frontmatter}\n\n#{body}"
      end

    String.trim_trailing(content) <> "\n"
  end

  defp render_meta_field(key, value) when is_list(value) do
    # Lists can contain scoped-capability maps (e.g. `%{"net.get" =>
    # %{"hosts" => ["*"]}}`). For homogeneous-scalar lists we use the
    # compact YAML inline form; for lists with maps we fall through to
    # a block format so the YAML parser can round-trip them.
    if Enum.all?(value, &scalar?/1) do
      "#{key}: [#{Enum.map_join(value, ", ", &to_string/1)}]"
    else
      "#{key}:\n" <>
        Enum.map_join(value, "\n", fn
          %{} = map when map_size(map) == 1 ->
            [{k, scope}] = Map.to_list(map)
            render_scoped_item(k, scope)

          other ->
            "  - #{other}"
        end)
    end
  end

  defp render_meta_field(key, value) when is_map(value) do
    "#{key}: #{Jason.encode!(value)}"
  end

  defp render_meta_field(key, value) do
    "#{key}: #{value}"
  end

  defp scalar?(v) when is_binary(v) or is_number(v) or is_atom(v) or is_boolean(v), do: true
  defp scalar?(_), do: false

  defp render_scoped_item(key, %{} = scope) do
    scope_lines =
      Enum.map_join(scope, "\n", fn {sk, sv} ->
        "      #{sk}: #{render_scope_value(sv)}"
      end)

    "  - #{key}:\n#{scope_lines}"
  end

  defp render_scope_value(list) when is_list(list) do
    "[" <> Enum.map_join(list, ", ", &format_scope_scalar/1) <> "]"
  end

  defp render_scope_value(other), do: format_scope_scalar(other)

  defp format_scope_scalar(v) when is_binary(v), do: yaml_quote_if_needed(v)
  defp format_scope_scalar(v), do: to_string(v)

  defp yaml_quote_if_needed(str) do
    cond do
      # YAML indicator characters at the start need quoting — `*`
      # is an alias reference, `&` is an anchor, `!` is a tag, etc.
      String.match?(str, ~r/^[\*&!|>@`?:]/) ->
        "\"" <> String.replace(str, "\"", "\\\"") <> "\""

      # Plain alphanumeric + hyphen/slash/dot is safe.
      String.match?(str, ~r/^[A-Za-z0-9_\-\/\.]+$/) ->
        str

      true ->
        "\"" <> String.replace(str, "\"", "\\\"") <> "\""
    end
  end

  defp maybe_field(_key, nil), do: nil
  defp maybe_field(key, value), do: "#{key}: #{value}"

  defp render_list(_key, nil), do: nil
  defp render_list(_key, []), do: nil
  defp render_list(key, items), do: "#{key}: [#{Enum.join(items, ", ")}]"

  defp generate_id do
    "rec_#{:erlang.unique_integer([:positive, :monotonic])}"
  end

  defp resolve_symlinks(path) do
    case :file.read_link(String.to_charlist(path)) do
      {:ok, target} ->
        resolved = Path.expand(to_string(target), Path.dirname(path))
        resolve_symlinks(resolved)

      {:error, _} ->
        # Not a symlink at the top level, but parent dirs might be.
        # Walk each segment resolving symlinks.
        [root | segments] = Path.split(path)

        Enum.reduce(segments, root, fn segment, acc ->
          candidate = Path.join(acc, segment)

          case :file.read_link(String.to_charlist(candidate)) do
            {:ok, target} -> Path.expand(to_string(target), acc)
            {:error, _} -> candidate
          end
        end)
    end
  end
end
