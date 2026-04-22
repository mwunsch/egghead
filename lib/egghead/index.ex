defmodule Egghead.Index do
  @moduledoc """
  SQLite-backed graph index for the Record Store.

  Owns a SQLite connection and provides all query operations against
  the materialized index. The index is a derived view — it can be
  dropped and rebuilt from the Markdown/org-mode files at any time.

  Tables:
  - `records` — core metadata (id, title, created, updated, author, class, format, source_path)
  - `record_tags` — tag associations
  - `record_links` — directed edges (source → target) for link graph traversal
  - `record_wikilinks` — richer link data (display text, fragment)
  - `records_fts` — FTS5 full-text search on id, title, and body
  - `meta` — schema version for drop-and-rebuild
  """

  use GenServer
  require Logger

  alias Egghead.Record
  alias Egghead.Record.Parser

  @schema_version "2"

  # --- Public API ---

  @doc """
  Starts the Index GenServer.

  ## Options

    * `:db_path` — path to the SQLite database file (default: `:memory:`)
    * `:name` — GenServer registration name (defaults to `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Upserts a record into the index.
  """
  @spec upsert_record(GenServer.server(), Record.t()) :: :ok
  def upsert_record(server \\ __MODULE__, record) do
    GenServer.call(server, {:upsert_record, record})
  end

  @doc """
  Removes a record from the index by its source path.
  """
  @spec delete_by_path(GenServer.server(), String.t()) :: :ok
  def delete_by_path(server \\ __MODULE__, path) do
    GenServer.call(server, {:delete_by_path, path})
  end

  @doc """
  Rebuilds the entire index from a records directory.
  """
  @spec rebuild(GenServer.server(), String.t()) :: :ok
  def rebuild(server \\ __MODULE__, records_dir) do
    GenServer.call(server, {:rebuild, records_dir}, :infinity)
  end

  @doc """
  Gets record metadata by id. Returns `{:ok, map}` or `{:error, :not_found}`.
  """
  @spec get_record_meta(GenServer.server(), String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def get_record_meta(server \\ __MODULE__, id) do
    GenServer.call(server, {:get_record_meta, id})
  end

  @doc """
  Looks up the row currently stored at `path`. Returns `{:ok, %{id, class}}`
  or `:none`. Used by the RecordStore to detect what was at this path
  before a file change so it can classify agent-record transitions
  (promote / demote / rename / reload) before doing the upsert.

  Lighter than `get_record_meta/2` — only returns the two fields needed
  for classification, no tag/link/meta hydration.
  """
  @spec lookup_by_path(GenServer.server(), String.t()) ::
          {:ok, %{id: String.t(), class: atom()}} | :none
  def lookup_by_path(server \\ __MODULE__, path) do
    GenServer.call(server, {:lookup_by_path, path})
  end

  @doc """
  Lists all records as lightweight metadata maps.
  """
  @spec list_records(GenServer.server()) :: [Record.t()]
  def list_records(server \\ __MODULE__) do
    GenServer.call(server, :list_records)
  end

  @doc """
  Searches for records matching the given tag.
  """
  @spec search_by_tag(GenServer.server(), String.t()) :: [Record.t()]
  def search_by_tag(server \\ __MODULE__, tag) do
    GenServer.call(server, {:search_by_tag, tag})
  end

  @doc """
  Searches for records matching the given class.
  """
  @spec search_by_class(GenServer.server(), Record.class()) :: [Record.t()]
  def search_by_class(server \\ __MODULE__, class) do
    GenServer.call(server, {:search_by_class, class})
  end

  @doc """
  Finds linked records from `id`, up to `depth` levels deep.
  Uses a recursive CTE in SQL.
  """
  @spec find_links(GenServer.server(), String.t(), non_neg_integer()) :: [Record.t()]
  def find_links(server \\ __MODULE__, id, depth \\ 1) do
    GenServer.call(server, {:find_links, id, depth})
  end

  @doc """
  Finds records that link TO the given id (reverse graph).
  """
  @spec find_backlinks(GenServer.server(), String.t()) :: [Record.t()]
  def find_backlinks(server \\ __MODULE__, id) do
    GenServer.call(server, {:find_backlinks, id})
  end

  @doc """
  Full-text search across record titles and bodies.
  Returns records ranked by relevance.
  """
  @spec search(GenServer.server(), String.t(), keyword()) :: [Record.t()]
  def search(server \\ __MODULE__, query, opts \\ []) do
    GenServer.call(server, {:search_fts, query, opts})
  end

  @doc """
  Returns recently modified or created records.

  ## Options

    * `:order_by` — `:updated` (default) or `:created`
    * `:limit` — max results (default: 20)
    * `:since` — ISO 8601 date string to filter from
  """
  @spec recent(GenServer.server(), keyword()) :: [Record.t()]
  def recent(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:recent, opts})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    db_path = Keyword.get(opts, :db_path, ":memory:")

    if db_path != ":memory:" do
      db_path |> Path.dirname() |> File.mkdir_p!()
    end

    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    # Set pragmas
    :ok = exec(conn, "PRAGMA journal_mode=WAL")
    :ok = exec(conn, "PRAGMA foreign_keys=ON")
    :ok = exec(conn, "PRAGMA synchronous=NORMAL")

    # Create or rebuild schema
    ensure_schema(conn)

    {:ok, %{conn: conn, db_path: db_path}}
  end

  @impl true
  def handle_call({:upsert_record, record}, _from, state) do
    do_upsert(state.conn, record)
    {:reply, :ok, state}
  end

  def handle_call({:delete_by_path, path}, _from, state) do
    exec(state.conn, "DELETE FROM records WHERE source_path = ?1", [path])
    {:reply, :ok, state}
  end

  def handle_call({:rebuild, records_dir}, _from, state) do
    do_rebuild(state.conn, records_dir)
    {:reply, :ok, state}
  end

  def handle_call({:get_record_meta, id}, _from, state) do
    result =
      case query_one(state.conn, "SELECT * FROM records WHERE id = ?1", [id]) do
        nil -> {:error, :not_found}
        row -> {:ok, row_to_meta(state.conn, row)}
      end

    {:reply, result, state}
  end

  def handle_call({:lookup_by_path, path}, _from, state) do
    result =
      case query_one(state.conn, "SELECT id, class FROM records WHERE source_path = ?1", [path]) do
        nil -> :none
        row -> {:ok, %{id: row.id, class: Egghead.Record.parse_class(row.class)}}
      end

    {:reply, result, state}
  end

  def handle_call(:list_records, _from, state) do
    rows = query_all(state.conn, "SELECT * FROM records ORDER BY updated DESC, created DESC")
    records = Enum.map(rows, &row_to_record(state.conn, &1))
    {:reply, records, state}
  end

  def handle_call({:search_by_tag, tag}, _from, state) do
    rows =
      query_all(
        state.conn,
        """
        SELECT r.* FROM records r
        JOIN record_tags rt ON rt.record_id = r.id
        WHERE rt.tag = ?1
        """,
        [tag]
      )

    {:reply, Enum.map(rows, &row_to_record(state.conn, &1)), state}
  end

  def handle_call({:search_by_class, class}, _from, state) do
    rows =
      query_all(state.conn, "SELECT * FROM records WHERE class = ?1", [to_string(class)])

    {:reply, Enum.map(rows, &row_to_record(state.conn, &1)), state}
  end

  def handle_call({:find_links, id, depth}, _from, state) do
    rows =
      query_all(
        state.conn,
        """
        WITH RECURSIVE
          edges(source_id, target_id) AS (
            SELECT source_id, target_id FROM record_links
            UNION
            SELECT source_id, target FROM record_wikilinks
          ),
          reachable(id, depth) AS (
            SELECT target_id, 1 FROM edges WHERE source_id = ?1
            UNION
            SELECT e.target_id, r.depth + 1
            FROM edges e
            JOIN reachable r ON e.source_id = r.id
            WHERE r.depth < ?2
              AND e.target_id != ?1
          )
        SELECT DISTINCT rec.* FROM records rec
        JOIN reachable ON rec.id = reachable.id
        WHERE rec.id != ?1
        """,
        [id, depth]
      )

    {:reply, Enum.map(rows, &row_to_record(state.conn, &1)), state}
  end

  def handle_call({:find_backlinks, id}, _from, state) do
    rows =
      query_all(
        state.conn,
        """
        SELECT DISTINCT r.* FROM records r
        WHERE r.id IN (
          SELECT source_id FROM record_links WHERE target_id = ?1
          UNION
          SELECT source_id FROM record_wikilinks WHERE target = ?1
        )
        """,
        [id]
      )

    {:reply, Enum.map(rows, &row_to_record(state.conn, &1)), state}
  end

  def handle_call({:search_fts, query, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)

    rows =
      query_all(
        state.conn,
        """
        SELECT r.* FROM records r
        WHERE r.id IN (
          SELECT id FROM records_fts WHERE records_fts MATCH ?1
          ORDER BY rank
          LIMIT ?2
        )
        """,
        [escape_fts(query), limit]
      )

    {:reply, Enum.map(rows, &row_to_record(state.conn, &1)), state}
  end

  def handle_call({:recent, opts}, _from, state) do
    order_by = Keyword.get(opts, :order_by, :updated)
    limit = Keyword.get(opts, :limit, 20)
    since = Keyword.get(opts, :since)

    col = if order_by == :created, do: "created", else: "updated"

    {where, params} =
      if since do
        {"WHERE #{col} >= ?1", [since]}
      else
        {"", []}
      end

    rows =
      query_all(
        state.conn,
        "SELECT * FROM records #{where} ORDER BY #{col} DESC LIMIT ?#{length(params) + 1}",
        params ++ [limit]
      )

    {:reply, Enum.map(rows, &row_to_record(state.conn, &1)), state}
  end

  @impl true
  def terminate(_reason, state) do
    Exqlite.Sqlite3.close(state.conn)
  end

  # --- Schema management ---

  defp ensure_schema(conn) do
    # Check if schema exists and is current version
    case get_schema_version(conn) do
      @schema_version ->
        :ok

      nil ->
        create_schema(conn)

      _old_version ->
        drop_schema(conn)
        create_schema(conn)
    end
  end

  defp get_schema_version(conn) do
    case query_one(conn, "SELECT name FROM sqlite_master WHERE type='table' AND name='meta'", []) do
      nil ->
        nil

      _ ->
        case query_one(conn, "SELECT value FROM meta WHERE key = 'schema_version'", []) do
          nil -> nil
          %{value: v} -> v
        end
    end
  end

  defp create_schema(conn) do
    exec(conn, """
    CREATE TABLE IF NOT EXISTS meta (
      key   TEXT PRIMARY KEY,
      value TEXT
    )
    """)

    exec(conn, """
    CREATE TABLE IF NOT EXISTS records (
      id          TEXT PRIMARY KEY,
      title       TEXT,
      created     TEXT,
      updated     TEXT,
      author      TEXT,
      class       TEXT NOT NULL DEFAULT 'durable',
      format      TEXT NOT NULL DEFAULT 'markdown',
      source_path TEXT NOT NULL UNIQUE
    )
    """)

    exec(conn, """
    CREATE TABLE IF NOT EXISTS record_tags (
      record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
      tag       TEXT NOT NULL,
      PRIMARY KEY (record_id, tag)
    )
    """)

    exec(conn, """
    CREATE TABLE IF NOT EXISTS record_links (
      source_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
      target_id TEXT NOT NULL,
      PRIMARY KEY (source_id, target_id)
    )
    """)

    exec(conn, """
    CREATE TABLE IF NOT EXISTS record_wikilinks (
      source_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
      target    TEXT NOT NULL,
      display   TEXT,
      fragment  TEXT
    )
    """)

    exec(conn, """
    CREATE TABLE IF NOT EXISTS record_meta (
      record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
      key       TEXT NOT NULL,
      value     TEXT,
      PRIMARY KEY (record_id, key)
    )
    """)

    exec(conn, """
    CREATE VIRTUAL TABLE IF NOT EXISTS records_fts USING fts5(
      id,
      title,
      body,
      tokenize='porter unicode61'
    )
    """)

    # Indexes
    exec(conn, "CREATE INDEX IF NOT EXISTS idx_record_tags_tag ON record_tags(tag)")
    exec(conn, "CREATE INDEX IF NOT EXISTS idx_record_links_target ON record_links(target_id)")
    exec(conn, "CREATE INDEX IF NOT EXISTS idx_records_class ON records(class)")
    exec(conn, "CREATE INDEX IF NOT EXISTS idx_records_created ON records(created)")
    exec(conn, "CREATE INDEX IF NOT EXISTS idx_records_updated ON records(updated)")

    exec(conn, "INSERT OR REPLACE INTO meta VALUES ('schema_version', ?1)", [@schema_version])
  end

  defp drop_schema(conn) do
    exec(conn, "DROP TABLE IF EXISTS record_meta")
    exec(conn, "DROP TABLE IF EXISTS record_wikilinks")
    exec(conn, "DROP TABLE IF EXISTS record_links")
    exec(conn, "DROP TABLE IF EXISTS record_tags")
    exec(conn, "DROP TABLE IF EXISTS records_fts")
    exec(conn, "DROP TABLE IF EXISTS records")
    exec(conn, "DROP TABLE IF EXISTS meta")
  end

  # --- Upsert / Delete ---

  defp do_upsert(conn, record) do
    exec(conn, "BEGIN")

    try do
      # If the file's id changed, remove the old entry by source_path
      # (source_path has a UNIQUE constraint, so this catches renames)
      exec(conn, "DELETE FROM records WHERE source_path = ?1 AND id != ?2", [
        record.source_path,
        record.id
      ])

      # Upsert record metadata
      exec(
        conn,
        """
        INSERT OR REPLACE INTO records (id, title, created, updated, author, class, format, source_path)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        """,
        [
          record.id,
          record.title,
          record.created,
          record.updated,
          record.author,
          to_string(record.class),
          to_string(record.format),
          record.source_path
        ]
      )

      # Replace tags
      exec(conn, "DELETE FROM record_tags WHERE record_id = ?1", [record.id])

      for tag <- record.tags do
        exec(conn, "INSERT INTO record_tags (record_id, tag) VALUES (?1, ?2)", [record.id, tag])
      end

      # Replace links
      exec(conn, "DELETE FROM record_links WHERE source_id = ?1", [record.id])

      for link <- Enum.uniq(record.links) do
        exec(conn, "INSERT INTO record_links (source_id, target_id) VALUES (?1, ?2)", [
          record.id,
          link
        ])
      end

      # Replace wikilinks
      exec(conn, "DELETE FROM record_wikilinks WHERE source_id = ?1", [record.id])

      for wl <- record.wikilinks || [] do
        exec(
          conn,
          "INSERT INTO record_wikilinks (source_id, target, display, fragment) VALUES (?1, ?2, ?3, ?4)",
          [record.id, wl.target, wl.display, wl.fragment]
        )
      end

      # Replace arbitrary metadata
      exec(conn, "DELETE FROM record_meta WHERE record_id = ?1", [record.id])

      for {key, value} <- record.meta || %{} do
        exec(
          conn,
          "INSERT INTO record_meta (record_id, key, value) VALUES (?1, ?2, ?3)",
          [record.id, to_string(key), Jason.encode!(value)]
        )
      end

      # Update FTS
      exec(conn, "DELETE FROM records_fts WHERE id = ?1", [record.id])

      exec(
        conn,
        "INSERT INTO records_fts (id, title, body) VALUES (?1, ?2, ?3)",
        [record.id, record.title || "", record.body || ""]
      )

      exec(conn, "COMMIT")
    rescue
      e ->
        exec(conn, "ROLLBACK")
        reraise e, __STACKTRACE__
    end
  end

  defp do_rebuild(conn, records_dir) do
    # Clear everything and re-scan
    exec(conn, "DELETE FROM record_meta")
    exec(conn, "DELETE FROM record_wikilinks")
    exec(conn, "DELETE FROM record_links")
    exec(conn, "DELETE FROM record_tags")
    exec(conn, "DELETE FROM records_fts")
    exec(conn, "DELETE FROM records")

    records_dir
    |> list_record_files()
    |> Enum.each(fn path ->
      case File.read(path) do
        {:ok, content} ->
          case Parser.parse(content, source_path: path, records_dir: records_dir) do
            {:ok, record} -> do_upsert(conn, Egghead.Skill.auto_classify(record))
            {:error, reason} -> Logger.warning("Skipping #{path}: #{inspect(reason)}")
          end

        {:error, _} ->
          :skip
      end
    end)
  end

  defp list_record_files(dir) do
    walk_directory(dir, dir)
  end

  defp walk_directory(current, root) do
    case File.ls(current) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          # Skip hidden directories (like .egghead/)
          if String.starts_with?(entry, ".") do
            []
          else
            full = Path.join(current, entry)

            cond do
              File.dir?(full) ->
                walk_directory(full, root)

              String.ends_with?(entry, ".md") or String.ends_with?(entry, ".org") ->
                [full]

              true ->
                []
            end
          end
        end)

      {:error, _} ->
        []
    end
  end

  # --- Row mapping ---

  defp row_to_record(conn, row) do
    meta = row_to_meta(conn, row)

    %Record{
      id: meta.id,
      title: meta.title,
      created: meta.created,
      updated: meta.updated,
      author: meta.author,
      tags: meta.tags,
      links: meta.links,
      wikilinks: meta.wikilinks,
      class: Record.parse_class(meta.class),
      meta: meta.meta,
      body: nil,
      ast: nil,
      outline: meta.outline,
      format: parse_format(meta.format),
      source_path: meta.source_path
    }
  end

  defp row_to_meta(conn, row) do
    id = row.id

    tags =
      query_all(conn, "SELECT tag FROM record_tags WHERE record_id = ?1 ORDER BY tag", [id])
      |> Enum.map(& &1.tag)

    links =
      query_all(
        conn,
        "SELECT target_id FROM record_links WHERE source_id = ?1 ORDER BY rowid",
        [id]
      )
      |> Enum.map(& &1.target_id)

    wikilinks =
      query_all(
        conn,
        "SELECT target, display, fragment FROM record_wikilinks WHERE source_id = ?1 ORDER BY rowid",
        [id]
      )
      |> Enum.map(fn wl -> %{target: wl.target, display: wl.display, fragment: wl.fragment} end)

    %{
      id: row.id,
      title: row.title,
      created: row.created,
      updated: row.updated,
      author: row.author,
      class: row.class,
      format: row.format,
      source_path: row.source_path,
      tags: tags,
      links: links,
      wikilinks: wikilinks,
      meta: load_record_meta(conn, id),
      outline: []
    }
  end

  defp load_record_meta(conn, record_id) do
    query_all(conn, "SELECT key, value FROM record_meta WHERE record_id = ?1 ORDER BY key", [
      record_id
    ])
    |> Map.new(fn row -> {row.key, Jason.decode!(row.value)} end)
  end

  defp parse_format("org"), do: :org
  defp parse_format(_), do: :markdown

  # Prepare user input for FTS5 MATCH.
  #
  # Splits the query into individual terms and joins with OR so that
  # records containing any of the terms are returned. FTS5 ranks results
  # by how many terms match (via bm25), so records matching all terms
  # sort higher. Each term is double-quoted to prevent FTS5 syntax
  # injection (operators like AND, OR, NOT, *, NEAR).
  defp escape_fts(query) do
    query
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(fn term ->
      escaped = String.replace(term, "\"", "\"\"")
      "\"#{escaped}\""
    end)
    |> Enum.join(" OR ")
  end

  # --- SQLite helpers ---

  defp exec(conn, sql, params \\ []) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    if params != [] do
      :ok = Exqlite.Sqlite3.bind(stmt, params)
    end

    case Exqlite.Sqlite3.step(conn, stmt) do
      :done -> :ok
      {:row, _} -> drain_and_done(conn, stmt)
      {:error, reason} -> raise "SQLite exec error: #{inspect(reason)}"
    end
  after
    # stmt may not be bound if prepare failed, but release is safe
    :ok
  end

  defp drain_and_done(conn, stmt) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      :done -> :ok
      {:row, _} -> drain_and_done(conn, stmt)
    end
  end

  defp query_all(conn, sql, params \\ []) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    if params != [] do
      :ok = Exqlite.Sqlite3.bind(stmt, params)
    end

    columns = Exqlite.Sqlite3.columns(conn, stmt) |> elem(1) |> Enum.map(&String.to_atom/1)
    collect_rows(conn, stmt, columns, [])
  end

  defp collect_rows(conn, stmt, columns, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, values} ->
        row = columns |> Enum.zip(values) |> Map.new()
        collect_rows(conn, stmt, columns, [row | acc])

      :done ->
        Enum.reverse(acc)
    end
  end

  defp query_one(conn, sql, params) do
    case query_all(conn, sql, params) do
      [row | _] -> row
      [] -> nil
    end
  end
end
