defmodule Egghead.TUI.Chat.ViewBenchTest do
  @moduledoc """
  Not a correctness test — a perf smoke test for chat transcript
  rendering. Skipped by default so CI stays fast. Run with:

      mix test --only bench test/egghead/tui/chat/view_bench_test.exs

  Prints ms-per-draw for a synthetic 200-entry transcript, redrawn
  N times (as if the user were typing into the input buffer on a
  long, quiet transcript). The MarkdownCache should make every
  draw after the first a pure lookup per entry.
  """

  use ExUnit.Case, async: false

  @moduletag :bench

  alias Egghead.TUI.Chat.{Entry, Model}
  alias Egghead.TUI.Chat.View
  alias Egghead.TUI.MarkdownCache

  defp synthetic_transcript(n) do
    for i <- 1..n do
      text = """
      Here is a paragraph of agent output number #{i}. It has
      **bold** and *italic* markup, a `code span`, and a
      [[wikilink-target-#{i}]] embedded in the middle of some prose
      to exercise the CommonMark renderer and the wikilink
      tokenizer. Finally, a closing sentence to pad the length.
      """

      Entry.agent("agents/scout-#{rem(i, 3)}", "scout#{rem(i, 3)}", text)
    end
  end

  defp model_with_transcript(entries) do
    %Model{
      room_id: "bench",
      width: 120,
      height: 40,
      transcript: entries,
      providers?: true
    }
  end

  defp time_ms(fun) do
    {t, _} = :timer.tc(fun)
    t / 1000.0
  end

  setup do
    # Start the cache if it isn't running (the test harness skips the
    # full app supervision tree).
    case GenServer.whereis(MarkdownCache) do
      nil -> MarkdownCache.start_link([])
      _ -> :ok
    end

    MarkdownCache.reset()
    :ok
  end

  test "render 200-entry transcript repeatedly" do
    entries = synthetic_transcript(200)
    model = model_with_transcript(entries)

    # Cold draw — Earmark fires for every entry.
    cold = time_ms(fn -> View.render(model) end)

    # Warm draws — every entry should hit the cache.
    iterations = 20

    warm_total =
      time_ms(fn ->
        for _ <- 1..iterations, do: View.render(model)
      end)

    warm_avg = warm_total / iterations

    IO.puts("""

    ---- chat view render bench ----
    entries:   #{length(entries)}
    cold:      #{:erlang.float_to_binary(cold, decimals: 1)} ms
    warm avg:  #{:erlang.float_to_binary(warm_avg, decimals: 1)} ms (#{iterations} draws)
    speedup:   #{:erlang.float_to_binary(cold / max(warm_avg, 0.01), decimals: 1)}x
    cache:     #{MarkdownCache.size()} entries
    --------------------------------
    """)

    # Sanity: warm should be noticeably faster than cold (>=2x).
    assert warm_avg < cold, "expected warm draw to be faster than cold"
  end
end
