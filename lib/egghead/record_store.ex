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

  alias Egghead.Index
  alias Egghead.Record
  alias Egghead.Record.Parser

  # --- State struct ---

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            records_dir: String.t(),
            watcher_pid: pid() | nil,
            index: GenServer.server()
          }

    defstruct records_dir: nil, watcher_pid: nil, index: Index
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
    GenServer.call(server, {:create_record, attrs})
  end

  @doc """
  Gets a record by its id, hydrated with full body and AST from disk.

  Returns `{:ok, record}` or `{:error, :not_found}`.
  """
  @spec get_record(GenServer.server(), String.t()) :: {:ok, Record.t()} | {:error, :not_found}
  def get_record(server \\ __MODULE__, id) do
    GenServer.call(server, {:get_record, id})
  end

  @doc """
  Lists all records in the store (lightweight, no body/ast).
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
  Finds linked records starting from the given id, traversing `depth` levels.
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
  """
  @spec search(GenServer.server(), String.t(), keyword()) :: [Record.t()]
  def search(server \\ __MODULE__, query, opts \\ []) do
    GenServer.call(server, {:search, query, opts})
  end

  @doc """
  Returns recently modified or created records.
  """
  @spec recent(GenServer.server(), keyword()) :: [Record.t()]
  def recent(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:recent, opts})
  end

  @doc """
  Reloads all records from the filesystem into the index.
  """
  @spec reload(GenServer.server()) :: :ok
  def reload(server \\ __MODULE__) do
    GenServer.call(server, :reload, :infinity)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    records_dir = Keyword.fetch!(opts, :records_dir)
    File.mkdir_p!(records_dir)
    # Resolve symlinks so file watcher paths match (e.g. /tmp -> /private/tmp on macOS)
    records_dir = records_dir |> Path.expand() |> resolve_symlinks()
    index = Keyword.get(opts, :index, Index)
    watch? = Keyword.get(opts, :watch, true)

    watcher_pid =
      if watch? do
        case FileSystem.start_link(dirs: [records_dir]) do
          {:ok, pid} ->
            FileSystem.subscribe(pid)
            pid

          {:error, _} ->
            nil
        end
      end

    state = %State{
      records_dir: records_dir,
      watcher_pid: watcher_pid,
      index: index
    }

    # Build the index from files
    Index.rebuild(index, records_dir)

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
          File.write!(path, content)

          case Parser.parse(content, source_path: path, records_dir: state.records_dir) do
            {:ok, record} ->
              Index.upsert_record(state.index, record)
              {:reply, {:ok, record}, state}

            {:error, reason} ->
              File.rm(path)
              {:reply, {:error, reason}, state}
          end
        end
    end
  end

  def handle_call({:get_record, id}, _from, state) do
    case Index.get_record_meta(state.index, id) do
      {:ok, meta} -> {:reply, hydrate(meta.source_path, state.records_dir), state}
      {:error, :not_found} -> {:reply, {:error, :not_found}, state}
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
    if record_file?(path) do
      handle_file_change(state, path)
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
            {:ok, record} -> Index.upsert_record(state.index, record)
            {:error, _} -> :skip
          end

        {:error, _} ->
          :skip
      end
    else
      Index.delete_by_path(state.index, path)
    end
  end

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

  defp render_markdown(attrs) do
    frontmatter =
      [
        "---",
        "id: #{attrs["id"]}",
        maybe_field("created", attrs["created"]),
        maybe_field("author", attrs["author"]),
        render_list("tags", attrs["tags"]),
        render_list("links", attrs["links"]),
        "class: #{attrs["class"] || "durable"}",
        "---"
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    title = attrs["title"]
    body = attrs["body"] || ""

    content =
      if title do
        "#{frontmatter}\n\n# #{title}\n\n#{body}"
      else
        "#{frontmatter}\n\n#{body}"
      end

    String.trim_trailing(content) <> "\n"
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
