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
  the agent roster, and seeds `agents`. The runtime-declared
  PubSub subscription then keeps the model in sync with new room
  events.
  """

  alias Egghead.Chat.Stream
  alias Egghead.OpenTUI.EditBuffer
  alias Egghead.TUI.Chat.Entry
  alias Egghead.TUI.{Completion, SelectList, ThemePicker}

  defmodule AgentPresence do
    @moduledoc """
    Sidebar row for one agent: id, display name, `:idle`/`:active`
    status, and the most recent context footprint from that agent's
    last call. `ctx_tokens` is NOT cumulative lifetime spend.
    """
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            status: :idle | :active,
            muted?: boolean(),
            # Current context footprint (last call's input + output tokens).
            # NOT cumulative lifetime spend.
            ctx_tokens: non_neg_integer(),
            ctx_window: non_neg_integer(),
            ctx_pct: float()
          }
    defstruct id: nil,
              name: nil,
              status: :idle,
              muted?: false,
              ctx_tokens: 0,
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
          completion: Completion.t() | nil,
          status_message: String.t() | nil,
          status_dismissable: boolean(),
          status_kind: :info | :warning,
          anim_frame: non_neg_integer(),
          providers?: boolean(),
          link_index: non_neg_integer() | nil,
          theme_picker: ThemePicker.t() | nil,
          action_picker: nil | {atom(), SelectList.t()}
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
            completion: nil,
            status_message: nil,
            status_dismissable: false,
            status_kind: :info,
            anim_frame: 0,
            providers?: false,
            link_index: nil,
            theme_picker: nil,
            action_picker: nil

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
      agents: hydrate_agents(room_id)
    }
  end

  def init(_other), do: %__MODULE__{}

  @doc """
  Switch to a different room without losing terminal-layout state
  (`:width`, `:height`) or app-mode flags (`:providers?`). Resets the
  per-room state — transcript, streams, pending activations, scroll,
  input, completion dropdowns, status — and rehydrates from the
  new room.

  Used by `/join` to avoid the brief flash of an 80x24 frame that a
  raw `Model.init/1` would produce until the next resize event.
  """
  @spec switch_room(t(), String.t()) :: t()
  def switch_room(%__MODULE__{} = m, room_id) do
    %{
      m
      | room_id: room_id,
        transcript: hydrate_transcript(room_id),
        agents: hydrate_agents(room_id),
        streams: %{},
        pending_activated: MapSet.new(),
        scroll: 0,
        input: %EditBuffer{},
        completion: nil,
        status_message: nil,
        status_dismissable: false,
        status_kind: :info,
        link_index: nil
    }
  end

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
    {streams, committed} = Stream.finalize_and_drop(m.streams, agent_id)
    %{m | streams: streams, transcript: m.transcript ++ committed}
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
  def clear_input(%__MODULE__{} = m),
    do: %{m | input: EditBuffer.new(), completion: nil}

  @spec input_text(t()) :: String.t()
  def input_text(%__MODULE__{input: buffer}), do: EditBuffer.to_text(buffer)

  @spec input_empty?(t()) :: boolean()
  def input_empty?(%__MODULE__{input: buffer}), do: EditBuffer.empty?(buffer)

  # ---- link navigation (wikilinks in transcript) ----------------------------

  @wikilink_re ~r/\[\[([^\]|]+)(?:\|[^\]]+)?\]\]/

  @doc "All wikilink targets found in the transcript, in order."
  @spec transcript_links(t()) :: [String.t()]
  def transcript_links(%__MODULE__{transcript: transcript}) do
    transcript
    |> Enum.flat_map(fn entry ->
      Regex.scan(@wikilink_re, entry.text || "")
      |> Enum.map(fn [_, target | _] -> target end)
    end)
    |> Enum.uniq()
  end

  @doc "Cycle forward through wikilinks. No-op when none exist."
  @spec link_next(t()) :: t()
  def link_next(%__MODULE__{} = model) do
    links = transcript_links(model)

    case links do
      [] ->
        model

      _ ->
        n = length(links)
        new_idx = if model.link_index == nil, do: 0, else: rem(model.link_index + 1, n)
        %{model | link_index: new_idx}
    end
  end

  @doc "Cycle backward through wikilinks."
  @spec link_prev(t()) :: t()
  def link_prev(%__MODULE__{} = model) do
    links = transcript_links(model)

    case links do
      [] ->
        model

      _ ->
        n = length(links)
        new_idx = if model.link_index == nil, do: n - 1, else: rem(model.link_index - 1 + n, n)
        %{model | link_index: new_idx}
    end
  end

  @doc "The currently-active wikilink target, or nil."
  @spec active_link(t()) :: String.t() | nil
  def active_link(%__MODULE__{link_index: nil}), do: nil

  def active_link(%__MODULE__{} = model) do
    Enum.at(transcript_links(model), model.link_index)
  end

  @doc "Exit link-nav mode."
  @spec link_deselect(t()) :: t()
  def link_deselect(%__MODULE__{} = model), do: %{model | link_index: nil}

  @doc "True when cycling links."
  @spec link_mode?(t()) :: boolean()
  def link_mode?(%__MODULE__{link_index: nil}), do: false
  def link_mode?(%__MODULE__{}), do: true

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

  defp message_to_entry(%{
         id: msg_id,
         sender: %{type: :agent, id: id, name: name},
         content: "/pass"
       }) do
    flavor = Egghead.Chat.PassActions.pick(msg_id)
    Entry.action(id, name, flavor)
  end

  defp message_to_entry(%{sender: %{type: :agent, id: id, name: name}, content: content}) do
    Entry.agent(id, name, content)
  end

  defp message_to_entry(_), do: nil

  @doc """
  Re-fetch the agent roster from the live system, merging fresh
  metadata (id, name, mute) with whatever per-row state the chat
  screen was already tracking (status, ctx_pct, ctx_window,
  ctx_tokens). Order is preserved: existing rows keep their
  position; new rows append in `Egghead.list_agents/0` order.

  Used both at room entry (`init/1`) and at hot-reload broadcast
  (`{:agent_roster_changed}` on the room topic).
  """
  @spec hydrate_agents(t() | String.t() | nil) :: [AgentPresence.t()]
  def hydrate_agents(%__MODULE__{} = m) do
    fresh = fetch_agents(m.room_id)
    by_id = Map.new(m.agents, fn a -> {a.id, a} end)

    {existing_ordered, _} =
      Enum.reduce(m.agents, {[], MapSet.new()}, fn a, {acc, seen} ->
        case Enum.find(fresh, &(&1.id == a.id)) do
          nil -> {acc, seen}
          updated -> {acc ++ [merge(a, updated)], MapSet.put(seen, a.id)}
        end
      end)

    seen_ids = MapSet.new(existing_ordered, & &1.id)
    new_rows = Enum.reject(fresh, &MapSet.member?(seen_ids, &1.id))

    existing_ordered ++
      Enum.map(new_rows, fn a -> Map.merge(%AgentPresence{}, sanitize(a, by_id)) end)
  end

  def hydrate_agents(room_id), do: fetch_agents(room_id)

  defp fetch_agents(nil) do
    # No room selected — fall back to the global running list so the
    # roster panel and pickers still have something to show.
    muted = MapSet.new()

    try do
      Egghead.list_agents()
      |> Enum.map(fn a -> agent_presence(a.id, a.name, muted) end)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp fetch_agents(room_id) do
    # The sidebar mirrors the *room's* actual roster, not the global
    # agent registry. An idle agent that has not been invited into
    # this room must not appear — otherwise the UI contradicts what
    # `idle: true` claims. The room's `agents` list is the source of
    # truth; display info is looked up per-id.
    muted = muted_set(room_id)
    joined = joined_list(room_id)
    by_id = list_agents_by_id()

    Enum.map(joined, fn id ->
      display = Map.get(by_id, id) || %{name: id}
      agent_presence(id, display.name, muted)
    end)
  end

  defp agent_presence(id, name, muted) do
    %AgentPresence{
      id: id,
      name: name || id,
      status: :idle,
      muted?: MapSet.member?(muted, id)
    }
  end

  defp joined_list(nil), do: []

  defp joined_list(room_id) do
    try do
      case Egghead.Chat.Room.get_state(room_id) do
        %{agents: list} when is_list(list) -> list
        _ -> []
      end
    catch
      _, _ -> []
    end
  end

  defp list_agents_by_id do
    try do
      Egghead.list_agents() |> Map.new(&{&1.id, &1})
    rescue
      _ -> %{}
    catch
      _, _ -> %{}
    end
  end

  defp merge(%AgentPresence{} = old, %AgentPresence{} = new) do
    # Carry forward live UI state (status, ctx_*); refresh identity (name,
    # muted?) from the new snapshot.
    %{old | name: new.name, muted?: new.muted?}
  end

  defp sanitize(a, _by_id), do: Map.from_struct(a)

  defp muted_set(nil), do: MapSet.new()

  defp muted_set(room_id) do
    try do
      room_id |> Egghead.Chat.Room.muted() |> MapSet.new()
    catch
      _, _ -> MapSet.new()
    end
  end

  defp display_name(agent_id, %__MODULE__{agents: agents}) do
    case Enum.find(agents, &(&1.id == agent_id)) do
      %AgentPresence{name: name} when is_binary(name) and name != "" -> name
      _ -> agent_id
    end
  end
end
