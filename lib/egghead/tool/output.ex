defmodule Egghead.Tool.Output do
  @moduledoc """
  Truncation and binary-detection policy for tool output.

  Tool results that exceed the context budget would otherwise blow
  out the conversation or get rejected by the model's API. This
  module caps output at a configurable token budget (default ~30k
  tokens ≈ 120KB), preferring the tail — the error message is
  usually at the end of a long build log, not the top.

  Binary output (non-UTF-8) is refused outright with a size-only
  summary; sending garbage bytes to the model wastes context and
  never helps.
  """

  # ~30k tokens, approximated as 4 chars/token.
  @default_max_bytes 120_000

  # How much of the budget goes to the head vs the tail when
  # truncating. 25% head + 75% tail, keeping the error usually
  # at the tail of a build log.
  @head_fraction 0.25

  @type truncation_result ::
          {:ok, String.t()}
          | {:truncated, String.t(),
             %{original_bytes: non_neg_integer(), elided_bytes: non_neg_integer()}}
          | {:binary, String.t()}

  @doc """
  Apply the truncation policy to a tool's output. Returns:

  - `{:ok, output}` if below the cap and valid UTF-8
  - `{:truncated, output, meta}` if truncated (head + `[...elided...]` + tail)
  - `{:binary, notice}` if not valid text (refused)

  The `max_bytes` option overrides the default cap.
  """
  @spec apply(binary(), keyword()) :: truncation_result()
  def apply(output, opts \\ []) when is_binary(output) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    cond do
      not String.valid?(output) ->
        {:binary, binary_notice(byte_size(output))}

      byte_size(output) <= max_bytes ->
        {:ok, output}

      true ->
        truncate(output, max_bytes)
    end
  end

  defp truncate(output, max_bytes) do
    original = byte_size(output)
    head_cap = floor(max_bytes * @head_fraction)
    tail_cap = max_bytes - head_cap

    head = safe_slice_head(output, head_cap)
    tail = safe_slice_tail(output, tail_cap)
    elided = original - byte_size(head) - byte_size(tail)

    elided_lines =
      output
      |> String.slice(String.length(head)..-(String.length(tail) + 1)//1)
      |> count_lines()

    notice =
      "\n\n[... #{format_bytes(elided)} elided (#{elided_lines} lines) — output truncated at #{format_bytes(max_bytes)} cap ...]\n\n"

    {:truncated, head <> notice <> tail, %{original_bytes: original, elided_bytes: elided}}
  end

  @doc """
  Append a chunk to a running buffer without exceeding the cap.
  Returns `{buffer, :ok}` if fully fit, `{buffer, :capped}` if
  the append pushed past the cap (further appends silently discard).

  Used during streaming: each chunk is appended to the in-memory
  buffer; once the cap is hit we stop accumulating (but keep
  streaming to the UI for visibility — truncation is for the
  tool_result that goes back to the model).
  """
  @spec append(binary(), binary(), keyword()) :: {binary(), :ok | :capped}
  def append(buffer, chunk, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    remaining = max_bytes - byte_size(buffer)

    cond do
      remaining <= 0 ->
        {buffer, :capped}

      byte_size(chunk) <= remaining ->
        {buffer <> chunk, :ok}

      true ->
        {buffer <> binary_part(chunk, 0, remaining), :capped}
    end
  end

  # --- helpers ---

  defp safe_slice_head(binary, cap) do
    # Slice by bytes, but back off to the last valid UTF-8 boundary
    # so we don't emit a mid-codepoint cut.
    raw = binary_part(binary, 0, min(cap, byte_size(binary)))
    trim_to_valid(raw, :trailing)
  end

  defp safe_slice_tail(binary, cap) do
    start = max(0, byte_size(binary) - cap)
    raw = binary_part(binary, start, byte_size(binary) - start)
    trim_to_valid(raw, :leading)
  end

  # If the slice ends/starts in the middle of a codepoint, peel bytes
  # until it's valid UTF-8.
  defp trim_to_valid(bin, :trailing) do
    if String.valid?(bin) do
      bin
    else
      case byte_size(bin) do
        0 -> bin
        n -> trim_to_valid(binary_part(bin, 0, n - 1), :trailing)
      end
    end
  end

  defp trim_to_valid(bin, :leading) do
    if String.valid?(bin) do
      bin
    else
      case byte_size(bin) do
        0 -> bin
        n -> trim_to_valid(binary_part(bin, 1, n - 1), :leading)
      end
    end
  end

  defp count_lines(str), do: str |> String.graphemes() |> Enum.count(&(&1 == "\n"))

  defp format_bytes(b) when b < 1024, do: "#{b} B"
  defp format_bytes(b) when b < 1_048_576, do: "#{Float.round(b / 1024, 1)} KB"
  defp format_bytes(b), do: "#{Float.round(b / 1_048_576, 1)} MB"

  defp binary_notice(bytes),
    do: "(non-text output, #{format_bytes(bytes)} suppressed — tool output must be UTF-8)"
end
