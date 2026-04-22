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

  # ETS table caching hydrated records by source_path, value
  # {mtime, record}. Parsing a large markdown body runs Earmark to
  # build an AST — hundreds of ms on a ~100 KB body. Without a cache,
  # navigating away from a record and back re-hits hydrate/2 and pays
  # the full parse cost every time. Mtime from a single stat is cheap
  # and authoritative — if the file changes on disk, the next hydrate
  # sees a different mtime and re-parses.
  @hydrate_cache :egghead_record_hydrate_cache

  # --- State struct ---

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            records_dir: String.t(),
            skills_dir: String.t() | nil,
            watcher_pid: pid() | nil,
            index: GenServer.server(),
            last_fingerprints: %{String.t() => term()}
          }

    # `last_fingerprints` keys a path to the `(mtime, size)` of the
    # last file event we processed for it. macOS FSEvents fires
    # twice per editor save (atomic write-then-rename); the second
    # event has the same fingerprint as the first, so we use this
    # map to skip the redundant reparse, reindex, agent restart,
    # and reload narration.
    defstruct records_dir: nil,
              skills_dir: nil,
              watcher_pid: nil,
              index: Index,
              last_fingerprints: %{}
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
  Moves a record to the trash (`.trash/` inside the records directory).

  The file is relocated preserving its relative path under `.trash/`, with
  a `deleted_at:` ISO 8601 timestamp injected into its frontmatter. The
  `.trash/` directory is skipped by the file-watcher and by index rebuild,
  so trashed records disappear from search and listings but remain on disk.

  Reversible — move the file back into place (or `mv` it out of `.trash/`)
  and the watcher re-indexes it.

  Returns `{:ok, trash_path}` (relative to records_dir) or `{:error, reason}`.
  """
  @spec trash_record(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def trash_record(server \\ __MODULE__, id) do
    Egghead.Node.call(server, {:trash_record, id})
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

    ensure_hydrate_cache()

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
          hydrate_cache_evict(path)

          case Parser.parse(content, source_path: path, records_dir: state.records_dir) do
            {:ok, record} ->
              Index.upsert_record(state.index, record)
              apply_agent_transition(state, classify_agent_transition(:none, record))
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
        prev_lookup = {:ok, %{id: meta.id, class: Egghead.Record.parse_class(meta.class)}}

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
            hydrate_cache_evict(path)

            case Parser.parse(content, source_path: path, records_dir: state.records_dir) do
              {:ok, record} ->
                Index.upsert_record(state.index, record)
                apply_agent_transition(state, classify_agent_transition(prev_lookup, record))
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

  def handle_call({:trash_record, id}, _from, state) do
    case Index.get_record_meta(state.index, id) do
      {:ok, meta} ->
        src_path = meta.source_path
        rel = Path.relative_to(src_path, state.records_dir)
        trash_path = Path.join([state.records_dir, ".trash", rel])
        final_path = resolve_trash_collision(trash_path)
        prev_lookup = {:ok, %{id: meta.id, class: Egghead.Record.parse_class(meta.class)}}

        case File.read(src_path) do
          {:ok, content} ->
            try do
              File.mkdir_p!(Path.dirname(final_path))
              File.write!(final_path, inject_deleted_at(content))
              File.rm!(src_path)
              hydrate_cache_evict(src_path)
              Index.delete_by_path(state.index, src_path)
              apply_agent_transition(state, classify_agent_transition(prev_lookup, nil))
              broadcast_record_change(id)

              # Cleanup now-empty intermediate dirs left behind by the move.
              prune_empty_dirs(Path.dirname(src_path), state.records_dir)

              {:reply, {:ok, Path.relative_to(final_path, state.records_dir)}, state}
            rescue
              e -> {:reply, {:error, Exception.message(e)}, state}
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
    hydrate_cache_clear()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    state =
      cond do
        in_dir?(path, state.skills_dir) and skill_manifest?(path) ->
          handle_skill_change(state, path)
          state

        in_dir?(path, state.records_dir) and record_file?(path, state.records_dir) ->
          handle_file_change(state, path)

        true ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    {:noreply, state}
  end

  # --- Private helpers ---

  defp handle_file_change(state, path) do
    fingerprint = Parser.file_fingerprint(path)
    last = Map.get(state.last_fingerprints, path)

    cond do
      # Same (mtime, size) as the previously-processed event — this
      # is the FSEvents-debounce no-op. Skip everything; the prior
      # event already reindexed and broadcast for identical content.
      fingerprint != nil and fingerprint == last ->
        state

      # File has gone away. Drop our fingerprint cache entry along
      # with the index row so a future re-create at this path
      # is correctly seen as new.
      fingerprint == nil ->
        do_handle_removal(state, path)

      true ->
        do_handle_change(state, path, fingerprint)
    end
  end

  defp do_handle_change(state, path, fingerprint) do
    hydrate_cache_evict(path)
    prev_lookup = Index.lookup_by_path(state.index, path)

    case File.read(path) do
      {:ok, content} ->
        case Parser.parse(content, source_path: path, records_dir: state.records_dir) do
          {:ok, record} ->
            record = maybe_promote_to_skill(record)
            Index.upsert_record(state.index, record)
            apply_agent_transition(state, classify_agent_transition(prev_lookup, record))
            broadcast_record_change(record.id)
            %{state | last_fingerprints: Map.put(state.last_fingerprints, path, fingerprint)}

          {:error, reason} ->
            Logger.warning("Skipping #{path}: #{inspect(reason)}")
            state
        end

      {:error, _} ->
        state
    end
  end

  defp do_handle_removal(state, path) do
    hydrate_cache_evict(path)
    prev_lookup = Index.lookup_by_path(state.index, path)
    Index.delete_by_path(state.index, path)
    apply_agent_transition(state, classify_agent_transition(prev_lookup, nil))
    broadcast_record_change(nil)
    %{state | last_fingerprints: Map.delete(state.last_fingerprints, path)}
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
    hydrate_cache_evict(path)

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

  # Classify what an incoming write means for the agent-supervisor and
  # for chat-room narration. Inputs:
  #
  # - `prev` — `Index.lookup_by_path/2` result for this path before the
  #   write: `{:ok, %{id, class}}` if a row was there, `:none` otherwise.
  # - `incoming` — the freshly-parsed `%Record{}`, or `nil` when the file
  #   was removed.
  #
  # Returns one of `{:promoted | :reloaded | :renamed | :demoted | :removed, ...}`
  # or `:noop` for the boring case (non-agent ↔ non-agent).
  @doc false
  def classify_agent_transition(prev, incoming) do
    case {prev, incoming} do
      {:none, %{class: :agent} = r} ->
        {:promoted, r}

      {{:ok, %{class: :agent, id: prev_id}}, nil} ->
        {:removed, prev_id}

      {{:ok, %{class: :agent, id: prev_id}}, %{class: :agent, id: prev_id} = r} ->
        {:reloaded, r}

      {{:ok, %{class: :agent, id: prev_id}}, %{class: :agent} = r} ->
        {:renamed, prev_id, r}

      {{:ok, %{class: :agent, id: prev_id}}, _non_agent_or_nil} when not is_nil(incoming) ->
        {:demoted, prev_id}

      {{:ok, %{class: _other}}, %{class: :agent} = r} ->
        {:promoted, r}

      _ ->
        :noop
    end
  end

  defp apply_agent_transition(_state, :noop), do: :ok

  defp apply_agent_transition(_state, {:promoted, record} = transition) do
    log_transition(transition)
    broadcast_agent_change({:promoted, record})
    start_agent_async(record)
  end

  defp apply_agent_transition(_state, {:reloaded, record} = transition) do
    log_transition(transition)
    broadcast_agent_change({:reloaded, record})
    # `start_agent` doubles as restart — terminates any existing process
    # under this id before bringing a fresh one up.
    start_agent_async(record)
  end

  defp apply_agent_transition(_state, {:renamed, prev_id, record} = transition) do
    log_transition(transition)
    broadcast_agent_change({:renamed, prev_id, record})
    stop_agent_async(prev_id)
    start_agent_async(record)
  end

  defp apply_agent_transition(_state, {:demoted, prev_id} = transition) do
    log_transition(transition)
    broadcast_agent_change({:demoted, prev_id})
    stop_agent_async(prev_id)
  end

  defp apply_agent_transition(_state, {:removed, prev_id} = transition) do
    log_transition(transition)
    broadcast_agent_change({:removed, prev_id})
    stop_agent_async(prev_id)
  end

  defp log_transition({:promoted, %{id: id}}), do: Logger.info("Agent transition: promoted #{id}")
  defp log_transition({:reloaded, %{id: id}}), do: Logger.info("Agent transition: reloaded #{id}")

  defp log_transition({:renamed, prev_id, %{id: new_id}}),
    do: Logger.info("Agent transition: renamed #{prev_id} → #{new_id}")

  defp log_transition({:demoted, id}), do: Logger.info("Agent transition: demoted #{id}")
  defp log_transition({:removed, id}), do: Logger.info("Agent transition: removed #{id}")

  defp broadcast_agent_change(change) do
    if Process.whereis(Egghead.PubSub) do
      Phoenix.PubSub.broadcast(
        Egghead.PubSub,
        records_topic(),
        {:agent_record_changed, change}
      )
    end
  end

  defp start_agent_async(record) do
    if Process.whereis(Egghead.Agent.Supervisor) do
      Task.start(fn -> Egghead.Agent.Supervisor.start_agent(record) end)
    end

    :ok
  end

  defp stop_agent_async(agent_id) do
    if Process.whereis(Egghead.Agent.Supervisor) do
      Task.start(fn -> Egghead.Agent.Supervisor.stop_agent(agent_id) end)
    end

    :ok
  end

  # A skill manifest in SKILLS_DIR is specifically a `SKILL.md` file —
  # `README.md`, `CLAUDE.md`, and other helper docs in a skill dir are
  # reference material, not skill definitions.
  defp skill_manifest?(path), do: Path.basename(path) == "SKILL.md"

  defp record_file?(path, records_dir) do
    ext = Path.extname(path)
    (ext == ".md" or ext == ".org") and not in_hidden_subdir?(path, records_dir)
  end

  # Skip paths whose relative-to-records_dir segments include any hidden
  # dir (starts with `.`). Mirrors the rebuild-scan filter in
  # `Index.walk_directory/2` so trashed files (`.trash/…`) and internal
  # state (`.egghead/…`) don't reindex via the live watcher.
  defp in_hidden_subdir?(path, records_dir) do
    path
    |> Path.relative_to(records_dir)
    |> Path.split()
    |> Enum.any?(&String.starts_with?(&1, "."))
  end

  # Append a basic ISO 8601 timestamp to the filename base when the
  # target already exists — keeps history when a record was trashed,
  # restored, and trashed again. e.g. `.trash/inbox/foo.20260421T221530.md`.
  defp resolve_trash_collision(path) do
    if File.exists?(path) do
      ext = Path.extname(path)
      base = Path.rootname(path)
      stamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
      "#{base}.#{stamp}#{ext}"
    else
      path
    end
  end

  # Inject `deleted_at:` into the frontmatter. Preserves whatever was
  # there; adds a frontmatter block if the file didn't have one.
  defp inject_deleted_at(content) do
    stamp = DateTime.utc_now() |> DateTime.to_iso8601()
    line = "deleted_at: #{stamp}\n"

    case String.split(content, "---\n", parts: 3) do
      ["", frontmatter, body] -> "---\n" <> frontmatter <> line <> "---\n" <> body
      _ -> "---\n" <> line <> "---\n\n" <> content
    end
  end

  # After moving a file out of a subdirectory, prune empty parent
  # directories up to (but not including) the records_dir root.
  # Stops at the first non-empty dir.
  defp prune_empty_dirs(dir, records_dir) do
    cond do
      Path.expand(dir) == Path.expand(records_dir) ->
        :ok

      not String.starts_with?(Path.expand(dir), Path.expand(records_dir)) ->
        :ok

      true ->
        case File.ls(dir) do
          {:ok, []} ->
            _ = File.rmdir(dir)
            prune_empty_dirs(Path.dirname(dir), records_dir)

          _ ->
            :ok
        end
    end
  end

  defp hydrate(nil, _records_dir), do: {:error, :not_found}

  defp hydrate(path, records_dir) do
    fingerprint = Parser.file_fingerprint(path)

    case hydrate_cache_lookup(path, fingerprint) do
      {:ok, record} ->
        {:ok, record}

      :miss ->
        hydrate_from_disk(path, records_dir, fingerprint)
    end
  end

  defp hydrate_from_disk(path, records_dir, fingerprint) do
    case File.read(path) do
      {:ok, content} ->
        case Parser.parse(content, source_path: path, records_dir: records_dir) do
          {:ok, record} ->
            hydrate_cache_put(path, fingerprint, record)
            {:ok, record}

          {:error, _} ->
            {:error, :parse_error}
        end

      {:error, _} ->
        {:error, :file_read_error}
    end
  end

  defp ensure_hydrate_cache do
    case :ets.whereis(@hydrate_cache) do
      :undefined ->
        :ets.new(@hydrate_cache, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end
  end

  defp hydrate_cache_lookup(_path, nil), do: :miss

  defp hydrate_cache_lookup(path, fingerprint) do
    case :ets.whereis(@hydrate_cache) do
      :undefined ->
        :miss

      _ ->
        case :ets.lookup(@hydrate_cache, path) do
          [{^path, ^fingerprint, record}] -> {:ok, record}
          _ -> :miss
        end
    end
  end

  defp hydrate_cache_put(_path, nil, _record), do: :ok

  defp hydrate_cache_put(path, fingerprint, record) do
    case :ets.whereis(@hydrate_cache) do
      :undefined -> :ok
      _ -> :ets.insert(@hydrate_cache, {path, fingerprint, record})
    end
  end

  defp hydrate_cache_evict(path) do
    case :ets.whereis(@hydrate_cache) do
      :undefined -> :ok
      _ -> :ets.delete(@hydrate_cache, path)
    end
  end

  defp hydrate_cache_clear do
    case :ets.whereis(@hydrate_cache) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@hydrate_cache)
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
  # for any field the caller didn't provide. `created`/`updated` are not
  # here intentionally — `updated` is filesystem-owned and never serialized,
  # and authored `created` (if present) flows through via `existing.meta`.
  #
  # Nil values in `new_attrs` are ignored (preserves the existing value).
  # The sentinel `:remove` deletes that key from the merged map — the
  # only way to unset a meta field via `update_record/2` in a single
  # write. Used by the `access:`-on-mutate dissolution path.
  defp merge_record_attrs(existing, new_attrs) do
    known_fields = %{
      "id" => existing.id,
      "title" => existing.title,
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

    # Overlay caller values; nil is a no-op, :remove deletes the key.
    new_attrs
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.reduce(base, fn
      {k, :remove}, acc -> Map.delete(acc, k)
      {k, v}, acc -> Map.put(acc, k, v)
    end)
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

  # Skip keys for the meta_lines pass. `updated` is filesystem-owned and
  # never written back. `created` is omitted from the explicit known-lines
  # below so that authored values (preserved in `meta`) flow through the
  # generic meta_lines renderer; filesystem-derived values stay out of yaml.
  @known_frontmatter_keys ~w(id updated author tags links class)

  defp render_markdown(attrs) do
    # Known fields in a stable order
    known_lines =
      [
        "---",
        "id: #{attrs["id"]}",
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
