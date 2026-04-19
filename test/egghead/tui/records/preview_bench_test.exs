defmodule Egghead.TUI.Records.PreviewBenchTest do
  @moduledoc """
  Not a correctness test — a perf smoke test for records preview
  rendering against a large real-world body (the egghead session
  log). Skipped by default. Run with:

      mix test --only bench test/egghead/tui/records/preview_bench_test.exs

  Synthesises a Model, hydrates a single large record, and times
  `recompute_preview/1` cold vs. cached. Also measures a sequence
  of 7 keystrokes to simulate the search-typing case the user
  reported ("typing 'sessio' lags").
  """

  use ExUnit.Case, async: false

  @moduletag :bench

  alias Egghead.TUI.MarkdownCache
  alias Egghead.TUI.Records.Model

  defp session_log_body do
    path = Path.expand("~/.egghead/meta/session-log.md")

    case File.read(path) do
      {:ok, bin} -> bin
      _ -> synthetic_large_body()
    end
  end

  # Fallback when the user's real session log isn't present — a
  # paragraph generator that produces a comparably large body.
  defp synthetic_large_body do
    for i <- 1..400 do
      """

      ## Section #{i}

      A paragraph of prose with **bold** and [[wikilinks]]. #{String.duplicate("filler words ", 8)}

      - bullet one
      - bullet two

      ```elixir
      def example_#{i}, do: :ok
      ```
      """
    end
    |> Enum.join()
  end

  defp time_ms(fun) do
    {t, _} = :timer.tc(fun)
    t / 1000.0
  end

  defp model_with_body(body) do
    %Model{
      width: 120,
      height: 40,
      selected_body: body,
      selected_id: "meta/session-log",
      selected_record: %Egghead.Record{
        id: "meta/session-log",
        title: "Session Log",
        body: body,
        links: [],
        wikilinks: []
      },
      preview_rendered: nil,
      preview_rendered_width: nil
    }
  end

  setup do
    case GenServer.whereis(MarkdownCache) do
      nil -> MarkdownCache.start_link([])
      _ -> :ok
    end

    MarkdownCache.reset()
    :ok
  end

  test "recompute_preview — cold vs cached" do
    body = session_log_body()
    size_kb = byte_size(body) / 1024

    cold = time_ms(fn -> Model.recompute_preview(model_with_body(body)) end)
    warm = time_ms(fn -> Model.recompute_preview(model_with_body(body)) end)

    IO.puts("""

    ---- records preview bench ----
    body size:     #{:erlang.float_to_binary(size_kb, decimals: 1)} KB
    cold render:   #{:erlang.float_to_binary(cold, decimals: 1)} ms
    cached render: #{:erlang.float_to_binary(warm, decimals: 1)} ms
    speedup:       #{:erlang.float_to_binary(cold / max(warm, 0.01), decimals: 1)}x
    --------------------------------
    """)

    assert warm < cold, "expected cached render to be faster than cold"
  end

  test "simulated search-typing across 7 keystrokes hitting the same record" do
    body = session_log_body()

    # First keystroke is the cold hit; subsequent ones should all be
    # cache hits as long as the top match stays the same record.
    total =
      time_ms(fn ->
        for _ <- 1..7 do
          Model.recompute_preview(model_with_body(body))
        end
      end)

    IO.puts("""

    ---- search-typing bench (7 keystrokes) ----
    total:     #{:erlang.float_to_binary(total, decimals: 1)} ms
    --------------------------------------------
    """)

    # Loose sanity: 7 hits on a big record should be fast enough
    # that the first cold render dominates.
    assert total < 5_000
  end
end
