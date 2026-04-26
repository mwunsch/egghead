defmodule Egghead.Chat.Stream do
  @moduledoc """
  Per-agent in-progress streaming buffer, shared by the TUI and
  the LiveView web surface.

  When an agent streams text, each surface accumulates deltas until
  a commit boundary is reached. The boundary is parameterized:

  - TUI is IRC-style: commit on `\\n` (one line = one `:agent`
    entry in the transcript), no trim (whitespace fidelity matters
    for indented code inside multi-line messages).
  - LiveView is bubble-style: commit on `\\n\\n` (one paragraph =
    one bubble), each committed chunk trimmed so padding stays
    tidy.

  `finalize_and_drop/2` fuses the "flush whatever is left + remove
  from container" operation into one call so callers can't commit
  without clearing — a prior version of the LiveView path forgot
  to clear and produced the `"Got it — fetching now.Interesting..."`
  concat bug.
  """

  alias Egghead.Chat.PassActions
  alias Egghead.TUI.Chat.Entry

  @type opts :: [commit_on: String.t(), trim: boolean()]
  @type t :: %__MODULE__{
          agent_id: String.t(),
          name: String.t(),
          current: String.t(),
          commit_on: String.t(),
          trim: boolean(),
          started_at: integer()
        }

  defstruct agent_id: nil,
            name: nil,
            current: "",
            commit_on: "\n",
            trim: false,
            started_at: 0

  @spec new(String.t(), String.t(), opts()) :: t()
  def new(agent_id, name, opts \\ []) do
    %__MODULE__{
      agent_id: agent_id,
      name: name,
      current: "",
      commit_on: Keyword.get(opts, :commit_on, "\n"),
      trim: Keyword.get(opts, :trim, false),
      started_at: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Append a streamed delta. Returns `{updated_stream,
  committed_entries}`. Any complete `commit_on`-delimited chunks
  in the running buffer become committed `:agent` entries; the
  trailing partial chunk stays in `current` as the live ghost
  bubble.
  """
  @spec append(t(), String.t()) :: {t(), [Entry.t()]}
  def append(%__MODULE__{} = s, delta) when is_binary(delta) do
    new_text = s.current <> delta

    case String.split(new_text, s.commit_on) do
      [single] ->
        {%{s | current: single}, []}

      parts ->
        {commits, [last]} = Enum.split(parts, -1)

        entries =
          commits
          |> Enum.map(&maybe_trim(&1, s.trim))
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&commit_entry(s, &1))

        {%{s | current: last}, entries}
    end
  end

  @doc """
  Flush whatever remains in `current` as a single trailing entry.
  Returns `[]` if empty (or if trimming leaves it empty).
  """
  @spec finalize(t()) :: [Entry.t()]
  def finalize(%__MODULE__{current: ""}), do: []

  def finalize(%__MODULE__{current: text, trim: trim} = s) do
    text = maybe_trim(text, trim)
    if text == "", do: [], else: [commit_entry(s, text)]
  end

  # Surface a standalone /pass chunk as an atmospheric action rather
  # than a literal "/pass" line in the transcript. This is a UI-only
  # transform — the Coordinator's Room.agent_pass path still handles
  # whole-turn passes through PassActions.pick. This catches the case
  # where an agent monologues prose AND emits /pass on its own line
  # (or its own paragraph) within the same turn: the prose entries
  # render normally, the /pass chunk renders atmospherically.
  defp commit_entry(%__MODULE__{} = s, text) do
    if String.trim(text) == "/pass" do
      flavor =
        PassActions.pick("#{s.agent_id}-#{s.started_at}-#{System.unique_integer([:positive])}")

      Entry.action(s.agent_id, s.name, flavor)
    else
      Entry.agent(s.agent_id, s.name, text)
    end
  end

  @doc """
  Finalize the stream for `agent_id` in `streams` and drop it from
  the map in one step. Returns `{updated_streams, committed_entries}`.
  Prefer this over manual `Map.get` + `finalize/1` + `Map.delete` —
  it's the only way to guarantee a commit can't leave stale buffered
  text behind.
  """
  @spec finalize_and_drop(%{optional(String.t()) => t()}, String.t()) ::
          {%{optional(String.t()) => t()}, [Entry.t()]}
  def finalize_and_drop(streams, agent_id) when is_map(streams) do
    case Map.pop(streams, agent_id) do
      {nil, streams} -> {streams, []}
      {stream, streams} -> {streams, finalize(stream)}
    end
  end

  @spec has_text?(t()) :: boolean()
  def has_text?(%__MODULE__{current: ""}), do: false
  def has_text?(_), do: true

  defp maybe_trim(text, true), do: String.trim(text)
  defp maybe_trim(text, false), do: text
end
