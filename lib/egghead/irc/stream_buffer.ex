defmodule Egghead.IRC.StreamBuffer do
  @moduledoc """
  Per-(room, agent) paragraph buffer for streaming agent output.

  Mid-stream token deltas (`{:agent_streaming, …}`) accumulate here until
  one or more complete paragraphs (split on `\\n\\n`) are ready to flush
  as PRIVMSG lines. The trailing partial sits in the buffer until either
  the next chunk completes another paragraph or the final
  `{:agent_message, msg}` arrives — at which point `take_tail/3` returns
  whatever the streaming path didn't already emit.

  Pure functions over a `%{{room_id, agent_id} => %{buffer, emitted}}`
  map, no process state of its own.
  """

  @type key :: {String.t(), String.t()}
  @type entry :: %{buffer: String.t(), emitted: non_neg_integer()}
  @type t :: %{optional(key) => entry}

  @doc """
  Append `delta` to the per-(room, agent) buffer. Returns
  `{to_emit, new_streams}` where `to_emit` is any complete paragraphs
  ready to flush as PRIVMSG (may be `""`).
  """
  @spec absorb(t, String.t(), String.t(), String.t()) :: {String.t(), t}
  def absorb(streams, room_id, agent_id, delta) do
    key = {room_id, agent_id}
    buffer = (streams[key] || %{buffer: "", emitted: 0}).buffer
    combined = buffer <> delta

    case last_paragraph_break(combined) do
      nil ->
        new = Map.put(streams, key, %{buffer: combined, emitted: emitted(streams, key)})
        {"", new}

      cut ->
        to_emit = binary_part(combined, 0, cut)
        rest = binary_part(combined, cut + 2, byte_size(combined) - cut - 2)

        new_emitted = emitted(streams, key) + cut + 2
        new = Map.put(streams, key, %{buffer: rest, emitted: new_emitted})
        {to_emit, new}
    end
  end

  @doc """
  On final `:agent_message`, return any text the streaming path didn't
  emit and clear the per-(room, agent) entry. Idempotent — if there
  was no streaming for this turn, returns the entire `full_content`.
  """
  @spec take_tail(t, String.t(), String.t(), String.t()) :: {String.t(), t}
  def take_tail(streams, room_id, agent_id, full_content) do
    key = {room_id, agent_id}

    case Map.get(streams, key) do
      nil ->
        {full_content, streams}

      %{emitted: e} ->
        tail =
          if e < byte_size(full_content) do
            binary_part(full_content, e, byte_size(full_content) - e)
          else
            ""
          end

        {tail, Map.delete(streams, key)}
    end
  end

  @doc "Drop every entry for a given room (used on PART / room_stopped)."
  @spec drop_room(t, String.t()) :: t
  def drop_room(streams, room_id) do
    streams
    |> Enum.reject(fn {{rid, _agent_id}, _} -> rid == room_id end)
    |> Map.new()
  end

  defp emitted(streams, key) do
    case Map.get(streams, key) do
      nil -> 0
      %{emitted: e} -> e
    end
  end

  # Last `\n\n` boundary in the buffer — that's how far we can safely
  # flush as completed paragraphs. Returns the byte offset of the first
  # `\n` of the boundary, or nil if none found.
  defp last_paragraph_break(text) do
    case :binary.matches(text, "\n\n") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end
end
