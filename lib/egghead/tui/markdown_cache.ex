defmodule Egghead.TUI.MarkdownCache do
  @moduledoc """
  Memoization layer around `Egghead.OpenTUI.Markdown.render/3`.

  The chat transcript view re-invokes the view on every input event,
  and the view walks every committed entry and re-parses its markdown.
  On long transcripts that is a full Earmark pass per entry per draw.
  Entries are immutable once committed, so the rendered output for a
  given `(text, width)` pair never changes.

  The cache is a single `:set` ETS table owned by this GenServer.
  Readers hit the table directly (`:public`, `read_concurrency: true`)
  so a view draw doesn't serialize through the process. Writers do the
  same — the worst case under a racy double-write is identical work
  done twice.

  Behaviour:

    * If the table is missing (tests, early startup) `render/3` falls
      through to a plain `Markdown.render/3` call. The cache is a
      performance aid, never a correctness requirement.
    * Size is unbounded. A typical session's transcript is a few
      thousand entries; even at a paragraph each that's a few MB of
      rendered rows. `reset/0` is available for tests and for the
      `/drop` path.
  """

  use GenServer

  alias Egghead.OpenTUI.Markdown

  @table :egghead_markdown_cache

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Render `text` at `width` with `opts`, caching the result. On miss,
  calls `Egghead.OpenTUI.Markdown.render/3`. On cache absence, falls
  through without caching.
  """
  @spec render(String.t(), pos_integer(), keyword()) :: Markdown.rendered()
  def render(text, width, opts \\ []) when is_binary(text) and is_integer(width) and width > 0 do
    key = {text, width, opts}

    case lookup(key) do
      {:ok, rows} ->
        rows

      :miss ->
        rows = Markdown.render(text, width, opts)
        put(key, rows)
        rows
    end
  end

  @doc "Empty the cache. Useful in tests and on explicit invalidation."
  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@table)
    end

    :ok
  end

  @doc "Number of cached entries. Useful for telemetry and tests."
  @spec size() :: non_neg_integer()
  def size do
    case :ets.whereis(@table) do
      :undefined -> 0
      _ -> :ets.info(@table, :size)
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, nil}
  end

  defp lookup(key) do
    case :ets.whereis(@table) do
      :undefined ->
        :miss

      _tid ->
        case :ets.lookup(@table, key) do
          [{^key, rows}] -> {:ok, rows}
          [] -> :miss
        end
    end
  end

  defp put(key, rows) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _tid -> :ets.insert(@table, {key, rows})
    end
  end
end
