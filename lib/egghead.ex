defmodule Egghead do
  @moduledoc """
  Egghead — a consultable record store with agent perspectives.

  This module provides the public API for interacting with the Record Store.
  Delegates to `Egghead.RecordStore` for all operations.
  """

  alias Egghead.Record
  alias Egghead.RecordStore

  @doc """
  Creates a new record in the store.

  ## Attributes

    * `:id` — record identifier (auto-generated if omitted)
    * `:title` — record title
    * `:author` — who created it
    * `:tags` — list of tag strings
    * `:links` — list of linked record ids
    * `:class` — `:durable`, `:inbox`, or `:deliberation` (default: `:durable`)
    * `:body` — the record body text
  """
  @spec create_record(map()) :: {:ok, Record.t()} | {:error, term()}
  defdelegate create_record(attrs), to: RecordStore

  @doc """
  Gets a record by id, hydrated with full body and AST from disk.
  """
  @spec get_record(String.t()) :: {:ok, Record.t()} | {:error, :not_found}
  defdelegate get_record(id), to: RecordStore

  @doc """
  Lists all records (lightweight, no body/ast).
  """
  @spec list_records() :: [Record.t()]
  defdelegate list_records(), to: RecordStore

  @doc """
  Finds records tagged with the given tag.
  """
  @spec search_by_tag(String.t()) :: [Record.t()]
  defdelegate search_by_tag(tag), to: RecordStore

  @doc """
  Finds records of the given class.
  """
  @spec search_by_class(Record.class()) :: [Record.t()]
  defdelegate search_by_class(class), to: RecordStore

  @doc """
  Traverses the link graph from a record, up to `depth` levels.
  """
  @spec find_links(String.t(), non_neg_integer()) :: [Record.t()]
  def find_links(id, depth \\ 1), do: RecordStore.find_links(RecordStore, id, depth)

  @doc """
  Finds records that link TO the given id (reverse graph / backlinks).
  """
  @spec find_backlinks(String.t()) :: [Record.t()]
  defdelegate find_backlinks(id), to: RecordStore

  @doc """
  Full-text search across record titles and bodies.
  """
  @spec search(String.t(), keyword()) :: [Record.t()]
  def search(query, opts \\ []), do: RecordStore.search(RecordStore, query, opts)

  @doc """
  Returns recently modified or created records.
  """
  @spec recent(keyword()) :: [Record.t()]
  def recent(opts \\ []), do: RecordStore.recent(RecordStore, opts)
end
