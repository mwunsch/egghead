defmodule Egghead.RecordStoreBenchTest do
  @moduledoc """
  Perf smoke test for the hydrated-record cache. Skipped by default.

      mix test --only bench test/egghead/record_store_bench_test.exs

  Simulates the "navigate away and back" flow in the records browser:
  hydrate a large record twice, measure how much of the second hit is
  absorbed by the cache.
  """

  use ExUnit.Case, async: false

  @moduletag :bench

  alias Egghead.Record.Parser

  defp large_body do
    path = Path.expand("~/.egghead/meta/session-log.md")

    case File.read(path) do
      {:ok, bin} -> {bin, path}
      _ -> synthetic()
    end
  end

  defp synthetic do
    body =
      1..400
      |> Enum.map(fn i ->
        "## Section #{i}\n\nProse with **bold** and [[wiki-#{i}]]. " <>
          String.duplicate("filler ", 20) <> "\n\n"
      end)
      |> Enum.join()

    path = Path.join(System.tmp_dir!(), "egghead-bench-#{:erlang.unique_integer([:positive])}.md")
    File.write!(path, body)
    {body, path}
  end

  defp time_ms(fun) do
    {t, _} = :timer.tc(fun)
    t / 1000.0
  end

  test "Parser.parse cold vs cached hydrate" do
    {_body, path} = large_body()

    # Use an isolated ETS table for the bench.
    table = :egghead_record_hydrate_cache

    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:set, :public, :named_table, read_concurrency: true])

      _ ->
        :ets.delete_all_objects(table)
    end

    # Prime the cache by calling Parser.parse directly (cold)
    content = File.read!(path)
    cold = time_ms(fn -> Parser.parse(content, source_path: path) end)
    {:ok, record} = Parser.parse(content, source_path: path)
    fingerprint = Parser.file_fingerprint(path)
    :ets.insert(table, {path, fingerprint, record})

    # Now simulate RecordStore.hydrate's cache hit path
    warm =
      time_ms(fn ->
        fp = Parser.file_fingerprint(path)
        [{^path, ^fp, _r}] = :ets.lookup(table, path)
      end)

    IO.puts("""

    ---- hydrate cache bench ----
    body:   #{byte_size(content)} bytes
    cold:   #{:erlang.float_to_binary(cold, decimals: 1)} ms
    warm:   #{:erlang.float_to_binary(warm, decimals: 1)} ms
    speed:  #{:erlang.float_to_binary(cold / max(warm, 0.01), decimals: 1)}x
    ------------------------------
    """)

    assert warm < cold
  end
end
