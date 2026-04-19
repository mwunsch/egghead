defmodule Egghead.Chat.TranscriptParser do
  @moduledoc """
  Parse a `class: transcript` record body back into a list of
  message maps (the same shape `Egghead.Chat.Room` emits).

  Inverse of `Egghead.Chat.Room.format_transcript/1`. The format
  is stable enough to round-trip: each message starts with a header
  line (`**Name** (`agent_id`) — timestamp` for agents,
  `**Name** — timestamp` for users), then a blank line, then the
  body, which may itself contain blank lines.

  Used by `Room.from_transcript/1` to rehydrate a room from a saved
  transcript record (`/join <transcript-id>`).
  """

  alias Egghead.Chat.Room.{Message, Sender}

  # Header line for an agent: `**Name** (`agents/scout`) — 2026-04-15T...`
  @agent_header ~r/^\*\*(?<name>[^*]+)\*\* \(`(?<id>[^`]+)`\) — (?<ts>\S+)$/

  # Header line for a user: `**Name** — 2026-04-15T...`
  @user_header ~r/^\*\*(?<name>[^*]+)\*\* — (?<ts>\S+)$/

  @doc """
  Parse a transcript record body into a list of `Message` structs.

  Returns `{:ok, messages}` on success or `{:error, reason}` if the
  body has no recognisable headers.
  """
  @spec parse(String.t(), String.t()) :: {:ok, [Message.t()]} | {:error, atom()}
  def parse(body, room_id) when is_binary(body) and is_binary(room_id) do
    lines = String.split(body, "\n")

    # Walk the lines, splitting on header lines. Each header opens a
    # new message; lines between headers form the content.
    {messages, _} =
      Enum.reduce(lines, {[], nil}, fn line, {acc, current} ->
        case header_match(line) do
          {:ok, header} ->
            acc = if current, do: acc ++ [finalize_current(current)], else: acc
            {acc, %{header: header, body_lines: []}}

          :no_match ->
            case current do
              nil -> {acc, nil}
              _ -> {acc, %{current | body_lines: current.body_lines ++ [line]}}
            end
        end
      end)
      |> finalize_trailing()

    case messages do
      [] -> {:error, :no_messages}
      _ -> {:ok, Enum.map(messages, &to_message(&1, room_id))}
    end
  end

  defp header_match(line) do
    cond do
      m = Regex.named_captures(@agent_header, line) ->
        {:ok, %{kind: :agent, name: m["name"], id: m["id"], ts: m["ts"]}}

      m = Regex.named_captures(@user_header, line) ->
        {:ok, %{kind: :user, name: m["name"], ts: m["ts"]}}

      true ->
        :no_match
    end
  end

  defp finalize_current(%{header: header, body_lines: lines}) do
    # Strip the leading blank line that always sits between header and
    # content, and the trailing blank line that separates messages.
    content =
      lines
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.reverse()
      |> Enum.join("\n")

    %{header: header, content: content}
  end

  defp finalize_trailing({acc, nil}), do: {acc, nil}
  defp finalize_trailing({acc, current}), do: {acc ++ [finalize_current(current)], nil}

  defp to_message(
         %{header: %{kind: :agent, name: name, id: id, ts: ts}, content: content},
         room_id
       ) do
    %Message{
      id: "rehydrate_#{:erlang.unique_integer([:positive, :monotonic])}",
      room_id: room_id,
      sender: %Sender{type: :agent, id: id, name: name},
      content: content,
      timestamp: parse_ts(ts),
      mentions: [],
      usage: nil
    }
  end

  defp to_message(%{header: %{kind: :user, name: name, ts: ts}, content: content}, room_id) do
    %Message{
      id: "rehydrate_#{:erlang.unique_integer([:positive, :monotonic])}",
      room_id: room_id,
      sender: %Sender{type: :user, id: name, name: name},
      content: content,
      timestamp: parse_ts(ts),
      mentions: [],
      usage: nil
    }
  end

  defp parse_ts(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
