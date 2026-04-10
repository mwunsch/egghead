defmodule Egghead.TUI.Chat.Stream do
  @moduledoc """
  Per-agent in-progress streaming buffer.

  When the Coordinator broadcasts `{:agent_streaming, _, agent_id,
  delta}`, the chat screen accumulates the delta in this struct's
  `current` field. Whenever a `\\n` line break appears, every
  complete line before the final fragment is committed as an
  `:agent` Entry in the transcript. The trailing partial line
  stays as the live ghost bubble until either another delta
  arrives or the agent finishes.

  This gives an IRC-style feel: lines appear in the transcript
  as complete messages, not token by token. The view layer
  reassembles consecutive agent entries for markdown rendering.

  `finalize/1` is called when the Room broadcasts the final
  `:agent_message` for an agent — anything left in `current` is
  flushed as one last entry.
  """

  alias Egghead.TUI.Chat.Entry

  @type t :: %__MODULE__{
          agent_id: String.t(),
          name: String.t(),
          current: String.t(),
          started_at: integer()
        }

  defstruct agent_id: nil, name: nil, current: "", started_at: 0

  @spec new(String.t(), String.t()) :: t()
  def new(agent_id, name) do
    %__MODULE__{
      agent_id: agent_id,
      name: name,
      current: "",
      started_at: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Append a streamed delta. Returns `{updated_stream,
  committed_entries}` — any complete `\\n`-delimited lines in
  the running buffer become committed entries; the trailing
  partial line stays in `current` as the live ghost bubble.
  """
  @spec append(t(), String.t()) :: {t(), [Entry.t()]}
  def append(%__MODULE__{} = s, delta) when is_binary(delta) do
    new_text = s.current <> delta

    case String.split(new_text, "\n") do
      [single] ->
        {%{s | current: single}, []}

      parts ->
        {commits, [last]} = Enum.split(parts, -1)

        entries =
          commits
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&Entry.agent(s.agent_id, s.name, &1))

        {%{s | current: last}, entries}
    end
  end

  @doc """
  Finalize the stream — flush whatever is in `current` as a single
  trailing entry. Returns `[]` if `current` is empty.
  """
  @spec finalize(t()) :: [Entry.t()]
  def finalize(%__MODULE__{current: ""}), do: []
  def finalize(%__MODULE__{current: text} = s), do: [Entry.agent(s.agent_id, s.name, text)]

  @spec has_text?(t()) :: boolean()
  def has_text?(%__MODULE__{current: ""}), do: false
  def has_text?(_), do: true
end
