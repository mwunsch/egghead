defmodule Egghead.RecordStore do
  @moduledoc """
  GenServer that manages the in-memory record index.

  Watches a configurable records directory on the filesystem, parses
  Markdown and org-mode files into `Egghead.Record` structs, and
  maintains an in-memory index for querying by id, tag, class, and links.

  The index stores lightweight records — metadata only, with `body` and
  `ast` set to `nil`. When you call `get_record/2`, the full record is
  hydrated from disk, including body, AST, and outline. Listing and
  search functions return lightweight index records.

  ## State

  The GenServer state is an explicit `%Egghead.RecordStore.State{}` struct
  containing the records directory path and a map of id => record.
  """

  use GenServer

  alias Egghead.Record
  alias Egghead.Record.Parser

  # --- State struct ---

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            records_dir: String.t(),
            watcher_pid: pid() | nil,
            records: %{String.t() => Record.t()}
          }

    defstruct records_dir: nil, watcher_pid: nil, records: %{}
  end

  # --- Public API ---

  @doc """
  Starts the RecordStore GenServer.

  ## Options

    * `:records_dir` — path to the directory containing record files (required)
    * `:watch` — whether to watch the filesystem for changes (default: `true`)
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
  Lists all records in the store.
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

  Returns a flat list of records reachable from the starting record's links,
  up to the given depth. Does not include the starting record itself.
  Avoids cycles.
  """
  @spec find_links(GenServer.server(), String.t(), non_neg_integer()) :: [Record.t()]
  def find_links(server \\ __MODULE__, id, depth \\ 1) do
    GenServer.call(server, {:find_links, id, depth})
  end

  @doc """
  Reloads all records from the filesystem.
  """
  @spec reload(GenServer.server()) :: :ok
  def reload(server \\ __MODULE__) do
    GenServer.call(server, :reload)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    records_dir = Keyword.fetch!(opts, :records_dir)
    watch? = Keyword.get(opts, :watch, true)
    File.mkdir_p!(records_dir)

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
      watcher_pid: watcher_pid
    }

    state = load_records(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:create_record, attrs}, _from, state) do
    id = Map.get(attrs, :id) || Map.get(attrs, "id") || generate_id()
    attrs = normalize_attrs(attrs, id)

    content = render_markdown(attrs)
    filename = "#{id}.md"
    path = Path.join(state.records_dir, filename)

    if Map.has_key?(state.records, id) or File.exists?(path) do
      {:reply, {:error, :already_exists}, state}
    else
      File.write!(path, content)

      case Parser.parse(content, source_path: path) do
        {:ok, record} ->
          state = %{state | records: Map.put(state.records, record.id, to_index(record))}
          {:reply, {:ok, record}, state}

        {:error, reason} ->
          File.rm(path)
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:get_record, id}, _from, state) do
    case Map.fetch(state.records, id) do
      {:ok, index_record} -> {:reply, hydrate(index_record), state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_records, _from, state) do
    {:reply, Map.values(state.records), state}
  end

  def handle_call({:search_by_tag, tag}, _from, state) do
    results =
      state.records
      |> Map.values()
      |> Enum.filter(&(tag in &1.tags))

    {:reply, results, state}
  end

  def handle_call({:search_by_class, class}, _from, state) do
    results =
      state.records
      |> Map.values()
      |> Enum.filter(&(&1.class == class))

    {:reply, results, state}
  end

  def handle_call({:find_links, id, depth}, _from, state) do
    results = traverse_links(state.records, id, depth, MapSet.new([id]))
    {:reply, results, state}
  end

  def handle_call(:reload, _from, state) do
    state = load_records(%{state | records: %{}})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    if record_file?(path) do
      state = reload_file(state, path)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    {:noreply, state}
  end

  # --- Private helpers ---

  defp load_records(state) do
    records =
      state.records_dir
      |> list_record_files()
      |> Enum.reduce(%{}, fn path, acc ->
        case File.read(path) do
          {:ok, content} ->
            case Parser.parse(content, source_path: path) do
              {:ok, record} -> Map.put(acc, record.id, to_index(record))
              {:error, _} -> acc
            end

          {:error, _} ->
            acc
        end
      end)

    %{state | records: records}
  end

  defp reload_file(state, path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Parser.parse(content, source_path: path) do
            {:ok, record} ->
              # Remove any old record that had this source_path (id may have changed)
              records =
                state.records
                |> Enum.reject(fn {_id, r} -> r.source_path == path end)
                |> Map.new()
                |> Map.put(record.id, to_index(record))

              %{state | records: records}

            {:error, _} ->
              state
          end

        {:error, _} ->
          state
      end
    else
      # File was deleted — remove any record from this path
      records =
        state.records
        |> Enum.reject(fn {_id, r} -> r.source_path == path end)
        |> Map.new()

      %{state | records: records}
    end
  end

  defp record_file?(path) do
    ext = Path.extname(path)
    ext == ".md" or ext == ".org"
  end

  defp list_record_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&(String.ends_with?(&1, ".md") or String.ends_with?(&1, ".org")))
        |> Enum.map(&Path.join(dir, &1))

      {:error, _} ->
        []
    end
  end

  defp traverse_links(_records, _id, 0, _visited), do: []

  defp traverse_links(records, id, depth, visited) do
    case Map.get(records, id) do
      nil ->
        []

      record ->
        record.links
        |> Enum.reject(&MapSet.member?(visited, &1))
        |> Enum.flat_map(fn link_id ->
          new_visited = MapSet.put(visited, link_id)

          case Map.get(records, link_id) do
            nil ->
              []

            linked ->
              [linked | traverse_links(records, link_id, depth - 1, new_visited)]
          end
        end)
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

  # Strip body and ast for index storage — metadata only
  defp to_index(record) do
    %{record | body: nil, ast: nil}
  end

  # Re-read from disk and parse to get full body + AST
  defp hydrate(%Record{source_path: nil} = record), do: {:ok, record}

  defp hydrate(%Record{source_path: path} = _index_record) do
    case File.read(path) do
      {:ok, content} ->
        case Parser.parse(content, source_path: path) do
          {:ok, record} -> {:ok, record}
          {:error, _} -> {:error, :parse_error}
        end

      {:error, _} ->
        {:error, :file_read_error}
    end
  end
end
