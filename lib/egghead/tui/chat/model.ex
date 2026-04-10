defmodule Egghead.TUI.Chat.Model do
  @moduledoc """
  Chat-screen model.

  The model is the single source of truth for what the screen
  draws. It owns its dimensions, the committed transcript, every
  in-progress agent stream, the input buffer, the presence
  sidebar, and any transient UI state (status flash, scroll
  offset, ellipsis tick).

  Updates flow through `Egghead.TUI.Chat.Update`; the view is a
  pure projection of this struct.

  ## Lifecycle

  When the App shell switches to chat mode it calls `init/1` with
  `room_id: id`. The constructor drains the room's existing
  transcript via `Egghead.Chat.Room.get_transcript/1`, hydrates
  the agent roster, and seeds `agents`. The PubSub subscription
  declared by `Egghead.TUI.Chat.subscriptions/1` then keeps the
  model in sync with new room events.
  """

  alias Egghead.OpenTUI.EditBuffer
  alias Egghead.TUI.Chat.{Entry, Mentions, Stream}

  defmodule AgentPresence do
    @moduledoc false
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            status: :idle | :active,
            session_tokens: non_neg_integer(),
            ctx_window: non_neg_integer(),
            ctx_pct: float()
          }
    defstruct id: nil,
              name: nil,
              status: :idle,
              session_tokens: 0,
              ctx_window: 0,
              ctx_pct: 0.0
  end

  @type t :: %__MODULE__{
          room_id: String.t() | nil,
          width: pos_integer(),
          height: pos_integer(),
          transcript: [Entry.t()],
          streams: %{String.t() => Stream.t()},
          pending_activated: MapSet.t(),
          agents: [AgentPresence.t()],
          scroll: non_neg_integer(),
          input: EditBuffer.t(),
          next_paste_id: pos_integer(),
          mention: Mentions.Context.t() | nil,
          command: map() | nil,
          status_message: String.t() | nil,
          anim_frame: non_neg_integer(),
          providers?: boolean()
        }

  defstruct room_id: nil,
            width: 80,
            height: 24,
            transcript: [],
            streams: %{},
            pending_activated: MapSet.new(),
            agents: [],
            scroll: 0,
            input: %EditBuffer{},
            next_paste_id: 1,
            mention: nil,
            command: nil,
            status_message: nil,
            anim_frame: 0,
            providers?: false

  @doc """
  Build a fresh model. The `:room_id` opt is required for the
  PubSub subscription and message-send path. If absent, the
  screen still renders but everything is read-only.

  Hydration of the existing transcript and agent roster happens
  here so the screen has something to draw on its very first
  frame, before any PubSub event arrives.
  """
  @spec init(keyword()) :: t()
  def init(opts) when is_list(opts) do
    room_id = Keyword.get(opts, :room_id)

    %__MODULE__{
      room_id: room_id,
      transcript: hydrate_transcript(room_id),
      agents: hydrate_agents()
    }
  end

  def init(_other), do: %__MODULE__{}

  # ---- transcript ----------------------------------------------------------

  @doc """
  Append a committed entry to the transcript. Used both directly
  (for `:user` / `:system` events) and indirectly via the stream
  commit path (`:agent` entries).
  """
  @spec append_entry(t(), Entry.t()) :: t()
  def append_entry(%__MODULE__{} = m, %Entry{} = entry) do
    %{m | transcript: m.transcript ++ [entry]}
  end

  @spec append_entries(t(), [Entry.t()]) :: t()
  def append_entries(%__MODULE__{} = m, []), do: m

  def append_entries(%__MODULE__{} = m, entries) when is_list(entries) do
    %{m | transcript: m.transcript ++ entries}
  end

  # ---- streams -------------------------------------------------------------

  @doc """
  Apply a streamed delta from `agent_id`. Pulls (or creates) the
  per-agent stream, appends, commits any complete `\\n\\n`-delimited
  paragraphs, and drops the agent from the activated-pending set
  so the ellipsis goes away as soon as real text arrives.
  """
  @spec apply_stream_delta(t(), String.t(), String.t()) :: t()
  def apply_stream_delta(%__MODULE__{} = m, agent_id, delta) do
    name = display_name(agent_id, m)
    stream = Map.get(m.streams, agent_id, Stream.new(agent_id, name))
    {stream, committed} = Stream.append(stream, delta)

    %{
      m
      | streams: Map.put(m.streams, agent_id, stream),
        transcript: m.transcript ++ committed,
        pending_activated: MapSet.delete(m.pending_activated, agent_id)
    }
  end

  @doc """
  Finalize a stream when the room broadcasts the agent's final
  `:agent_message`. Anything left in the buffer is flushed.
  """
  @spec finalize_stream(t(), String.t()) :: t()
  def finalize_stream(%__MODULE__{} = m, agent_id) do
    case Map.get(m.streams, agent_id) do
      nil ->
        m

      stream ->
        committed = Stream.finalize(stream)

        %{
          m
          | streams: Map.delete(m.streams, agent_id),
            transcript: m.transcript ++ committed
        }
    end
  end

  @spec drop_stream(t(), String.t()) :: t()
  def drop_stream(%__MODULE__{} = m, agent_id) do
    %{
      m
      | streams: Map.delete(m.streams, agent_id),
        pending_activated: MapSet.delete(m.pending_activated, agent_id)
    }
  end

  # ---- input ---------------------------------------------------------------

  @spec set_buffer(t(), EditBuffer.t()) :: t()
  def set_buffer(%__MODULE__{} = m, %EditBuffer{} = buffer) do
    %{m | input: buffer}
  end

  @spec clear_input(t()) :: t()
  def clear_input(%__MODULE__{} = m), do: %{m | input: EditBuffer.new(), mention: nil, command: nil}

  @spec input_text(t()) :: String.t()
  def input_text(%__MODULE__{input: buffer}), do: EditBuffer.to_text(buffer)

  @spec input_empty?(t()) :: boolean()
  def input_empty?(%__MODULE__{input: buffer}), do: EditBuffer.empty?(buffer)

  # ---- internals -----------------------------------------------------------

  defp hydrate_transcript(nil), do: []

  defp hydrate_transcript(room_id) do
    case safe_get_transcript(room_id) do
      nil ->
        []

      msgs ->
        msgs
        |> Enum.map(&message_to_entry/1)
        |> Enum.reject(&is_nil/1)
    end
  end

  defp safe_get_transcript(room_id) do
    try do
      Egghead.Chat.Room.get_transcript(room_id)
    catch
      :exit, _ -> nil
    end
  end

  defp message_to_entry(%{sender: %{type: :user, name: name}, content: content}) do
    Entry.user(name, content)
  end

  defp message_to_entry(%{sender: %{type: :agent, id: id, name: name}, content: content}) do
    Entry.agent(id, name, content)
  end

  defp message_to_entry(_), do: nil

  defp hydrate_agents do
    try do
      Egghead.list_agents()
      |> Enum.map(fn a ->
        %AgentPresence{id: a.id, name: a.name, status: :idle}
      end)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp display_name(agent_id, %__MODULE__{agents: agents}) do
    case Enum.find(agents, &(&1.id == agent_id)) do
      %AgentPresence{name: name} -> name
      _ -> agent_id |> String.split("/") |> List.last() |> String.capitalize()
    end
  end
end
