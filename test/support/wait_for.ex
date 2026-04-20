defmodule Egghead.Test.WaitFor do
  @moduledoc """
  Test helpers for waiting on asynchronous conditions without blind sleeps.

  Prefer these over `Process.sleep/1` for any case where a test is waiting
  for external state (file writes, supervised processes becoming ready,
  debounced flushes, etc.). Blind sleeps are flaky under full-suite load
  and waste time on fast paths.
  """

  @poll_ms 25
  @default_deadline_ms 5_000

  @doc """
  Poll `fun` every ~25ms until it returns a truthy value, or give up after
  `deadline_ms`. Returns the truthy value (so it's usable as an assertion
  target) or `false` on timeout.

  ## Examples

      assert Egghead.Test.WaitFor.wait_for(fn -> Server.status(pid) == :ready end)

      assert {:ok, body} =
               Egghead.Test.WaitFor.wait_for(fn ->
                 case Egghead.get_record(id) do
                   {:ok, %{body: b}} -> {:ok, b}
                   _ -> false
                 end
               end)
  """
  @spec wait_for((-> term()), pos_integer()) :: term() | false
  def wait_for(fun, deadline_ms \\ @default_deadline_ms) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fn -> :ok end)
    |> Enum.reduce_while(false, fn _, _ ->
      case fun.() do
        falsy when falsy in [false, nil] ->
          if System.monotonic_time(:millisecond) > deadline do
            {:halt, false}
          else
            Process.sleep(@poll_ms)
            {:cont, false}
          end

        truthy ->
          {:halt, truthy}
      end
    end)
  end
end
