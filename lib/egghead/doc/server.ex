defmodule Egghead.Doc.Server do
  @moduledoc """
  Per-record Y.Doc server. Holds a Yex.Doc in memory while browser
  editors are attached, serializing edits back to disk through the
  existing RecordStore write barrier.

  Lifecycle: starts on first client join, shuts down after the last
  client disconnects + a flush delay. The file on disk remains the
  source of truth; this process is an ephemeral materialization.
  """

  use GenServer, restart: :transient

  @flush_delay_ms 5_000
  @debounce_trailing_ms 400
  @debounce_max_ms 2_000

  defstruct [
    :record_id,
    :doc,
    :text,
    :last_written_body,
    :debounce_ref,
    :debounce_start,
    :shutdown_ref,
    clients: MapSet.new(),
    seeded: false,
    dirty: false
  ]

  # --- Public API ---

  def start_link(opts) do
    record_id = Keyword.fetch!(opts, :record_id)
    name = via(record_id)
    GenServer.start_link(__MODULE__, record_id, name: name)
  end

  def ensure_started(record_id) do
    case Registry.lookup(Egghead.Doc.Registry, record_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> Egghead.Doc.Supervisor.start_server(record_id)
    end
  end

  def attach(record_id, client_pid) do
    GenServer.call(via(record_id), {:attach, client_pid})
  end

  def detach(record_id, client_pid) do
    GenServer.cast(via(record_id), {:detach, client_pid})
  end

  def apply_update(record_id, update) do
    GenServer.cast(via(record_id), {:yjs_update, update})
  end

  def get_state(record_id) do
    GenServer.call(via(record_id), :get_state)
  end

  @doc """
  Check if a Doc.Server is currently running for this record
  (i.e., a browser has the document open).
  """
  def alive?(record_id) do
    Registry.lookup(Egghead.Doc.Registry, record_id) != []
  end

  @doc """
  Apply an agent's edit through the CRDT, with visible cursor movement.

  Diffs the current body against `new_body`, applies ops in chunks
  so connected browsers see the agent "typing". Broadcasts agent
  cursor position between chunks.

  Returns `:ok` or `{:error, reason}`.
  """
  def agent_edit(record_id, agent_id, new_body) do
    GenServer.call(via(record_id), {:agent_edit, agent_id, new_body}, 30_000)
  end

  defp via(record_id) do
    {:via, Registry, {Egghead.Doc.Registry, record_id}}
  end

  # --- Callbacks ---

  @impl true
  def init(record_id) do
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(Egghead.PubSub, "records:changes")

    state = %__MODULE__{record_id: record_id}
    {:ok, state, {:continue, :seed}}
  end

  @impl true
  def handle_continue(:seed, %{seeded: true} = state), do: {:noreply, state}

  def handle_continue(:seed, state) do
    case Egghead.get_record(state.record_id) do
      {:ok, record} ->
        doc = Yex.Doc.new()
        text = Yex.Doc.get_text(doc, "content")
        Yex.Doc.monitor_update_v1(doc)

        if record.body && record.body != "" do
          Yex.Text.insert(text, 0, record.body)
        end

        {:noreply,
         %{state | doc: doc, text: text, last_written_body: record.body || "", seeded: true}}

      {:error, _} ->
        {:stop, {:shutdown, :record_not_found}, state}
    end
  end

  @impl true
  def handle_call({:attach, client_pid}, _from, state) do
    Process.monitor(client_pid)
    state = cancel_shutdown(state)
    state = %{state | clients: MapSet.put(state.clients, client_pid)}

    {:ok, update} = Yex.encode_state_as_update(state.doc)
    {:reply, {:ok, update}, state}
  end

  def handle_call(:get_state, _from, state) do
    {:ok, update} = Yex.encode_state_as_update(state.doc)
    {:reply, {:ok, update}, state}
  end

  def handle_call({:agent_edit, agent_id, new_body}, _from, state) do
    current_body = Yex.Text.to_string(state.text)

    if current_body == new_body do
      {:reply, :ok, state}
    else
      state = perform_agent_edit(state, agent_id, current_body, new_body)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:detach, client_pid}, state) do
    state = %{state | clients: MapSet.delete(state.clients, client_pid)}
    state = maybe_schedule_shutdown(state)
    {:noreply, state}
  end

  def handle_cast({:yjs_update, update}, state) do
    Yex.apply_update(state.doc, update)
    broadcast_to_clients(state, {:yjs_update, update})
    state = mark_dirty(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:update_v1, update, :external, _meta}, state) do
    broadcast_to_clients(state, {:yjs_update, update})
    {:noreply, mark_dirty(state)}
  end

  def handle_info({:update_v1, update, :agent, _meta}, state) do
    broadcast_to_clients(state, {:yjs_update, update})
    {:noreply, state}
  end

  def handle_info({:update_v1, _update, _origin, _meta}, state) do
    {:noreply, state}
  end

  def handle_info({:record_changed, record_id}, %{record_id: record_id} = state) do
    state = reconcile_external_change(state)
    {:noreply, state}
  end

  def handle_info({:record_changed, _other_id}, state), do: {:noreply, state}

  def handle_info(:debounce_flush, state) do
    state = flush_to_disk(state)
    {:noreply, state}
  end

  def handle_info(:shutdown_timeout, %{clients: clients} = state) do
    if MapSet.size(clients) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, %{state | shutdown_ref: nil}}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | clients: MapSet.delete(state.clients, pid)}
    state = maybe_schedule_shutdown(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.dirty and state.seeded do
      try do
        flush_to_disk_sync(state)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # --- Internal ---

  defp reconcile_external_change(state) do
    case Egghead.get_record(state.record_id) do
      {:ok, record} ->
        file_body = record.body || ""

        if file_body == state.last_written_body do
          state
        else
          apply_external_diff(state, file_body)
        end

      {:error, _} ->
        state
    end
  end

  defp apply_external_diff(state, new_body) do
    # y_ex uses UTF-8 byte offsets for indices, so diff on bytes
    old_bytes = :binary.bin_to_list(state.last_written_body)
    new_bytes = :binary.bin_to_list(new_body)

    ops = List.myers_difference(old_bytes, new_bytes)

    Yex.Doc.transaction(state.doc, :external, fn ->
      apply_diff_ops(state.text, ops, 0)
    end)

    %{state | last_written_body: new_body}
  end

  defp apply_diff_ops(_text, [], _pos), do: :ok

  defp apply_diff_ops(text, [{:eq, bytes} | rest], pos) do
    apply_diff_ops(text, rest, pos + length(bytes))
  end

  defp apply_diff_ops(text, [{:del, bytes} | rest], pos) do
    Yex.Text.delete(text, pos, length(bytes))
    apply_diff_ops(text, rest, pos)
  end

  defp apply_diff_ops(text, [{:ins, bytes} | rest], pos) do
    str = :binary.list_to_bin(bytes)
    Yex.Text.insert(text, pos, str)
    apply_diff_ops(text, rest, pos + length(bytes))
  end

  # --- Agent CRDT editing ---

  @agent_chunk_delay_ms 150

  defp perform_agent_edit(state, agent_id, current_body, new_body) do
    # Resolve agent name and color from record frontmatter
    {name, color} = agent_display(agent_id)

    # Broadcast agent cursor appearance
    broadcast_to_clients(state, {:agent_cursor, %{
      agent_id: agent_id, name: name, color: color, pos: 0, active: true
    }})

    # Diff current Y.Text content against new body (byte-level)
    old_bytes = :binary.bin_to_list(current_body)
    new_bytes = :binary.bin_to_list(new_body)
    ops = List.myers_difference(old_bytes, new_bytes)

    # Apply ops in chunks with cursor position updates
    apply_agent_ops(state, agent_id, name, color, ops, 0)

    # Mark dirty so debounce flushes to disk
    state = mark_dirty(state)

    # Broadcast agent cursor removal
    broadcast_to_clients(state, {:agent_cursor, %{
      agent_id: agent_id, name: name, color: color, pos: 0, active: false
    }})

    state
  end

  defp apply_agent_ops(_state, _agent_id, _name, _color, [], _pos), do: :ok

  defp apply_agent_ops(state, agent_id, name, color, [{:eq, bytes} | rest], pos) do
    apply_agent_ops(state, agent_id, name, color, rest, pos + length(bytes))
  end

  defp apply_agent_ops(state, agent_id, name, color, [{:del, bytes} | rest], pos) do
    Yex.Doc.transaction(state.doc, :agent, fn ->
      Yex.Text.delete(state.text, pos, length(bytes))
    end)

    broadcast_cursor(state, agent_id, name, color, pos)
    Process.sleep(@agent_chunk_delay_ms)
    apply_agent_ops(state, agent_id, name, color, rest, pos)
  end

  defp apply_agent_ops(state, agent_id, name, color, [{:ins, bytes} | rest], pos) do
    str = :binary.list_to_bin(bytes)

    # Split large inserts into lines for visible animation
    lines = split_keeping_newlines(str)

    pos =
      Enum.reduce(lines, pos, fn line, pos ->
        Yex.Doc.transaction(state.doc, :agent, fn ->
          Yex.Text.insert(state.text, pos, line)
        end)

        new_pos = pos + byte_size(line)
        broadcast_cursor(state, agent_id, name, color, new_pos)
        Process.sleep(@agent_chunk_delay_ms)
        new_pos
      end)

    apply_agent_ops(state, agent_id, name, color, rest, pos)
  end

  defp broadcast_cursor(state, agent_id, name, color, pos) do
    broadcast_to_clients(state, {:agent_cursor, %{
      agent_id: agent_id, name: name, color: color, pos: pos, active: true
    }})
  end

  defp split_keeping_newlines(str) do
    # "foo\nbar\nbaz" → ["foo\n", "bar\n", "baz"]
    str
    |> String.split(~r/(?<=\n)/)
    |> Enum.reject(&(&1 == ""))
  end

  defp agent_display(agent_id) do
    case Egghead.get_record(agent_id) do
      {:ok, record} ->
        name = record.title || agent_id
        color = get_in(record.meta, ["color"]) || agent_color(agent_id)
        {name, color}

      _ ->
        {agent_id, agent_color(agent_id)}
    end
  end

  @agent_colors [
    "#e84855", "#30bced", "#6eeb83", "#ffbc42",
    "#8b5cf6", "#f472b6", "#34d399", "#fb923c"
  ]

  defp agent_color(agent_id) do
    hash = :erlang.phash2(agent_id)
    Enum.at(@agent_colors, rem(hash, length(@agent_colors)))
  end

  defp mark_dirty(state) do
    state = %{state | dirty: true}
    schedule_debounce(state)
  end

  defp schedule_debounce(state) do
    now = System.monotonic_time(:millisecond)

    if state.debounce_ref do
      Process.cancel_timer(state.debounce_ref)
    end

    start = state.debounce_start || now
    elapsed = now - start

    delay =
      if elapsed >= @debounce_max_ms do
        0
      else
        min(@debounce_trailing_ms, @debounce_max_ms - elapsed)
      end

    ref = Process.send_after(self(), :debounce_flush, delay)
    %{state | debounce_ref: ref, debounce_start: start}
  end

  defp flush_to_disk(state) do
    if state.dirty and state.seeded do
      flush_to_disk_sync(state)
    else
      state
    end
  end

  defp flush_to_disk_sync(state) do
    body = Yex.Text.to_string(state.text)

    case Egghead.update_record(state.record_id, %{body: body}) do
      {:ok, _} ->
        %{state | last_written_body: body, dirty: false, debounce_ref: nil, debounce_start: nil}

      {:error, _} ->
        state
    end
  end

  defp broadcast_to_clients(%{clients: clients}, message) do
    Enum.each(clients, fn pid ->
      send(pid, {:doc_update, message})
    end)
  end

  defp maybe_schedule_shutdown(%{clients: clients} = state) do
    if MapSet.size(clients) == 0 do
      ref = Process.send_after(self(), :shutdown_timeout, @flush_delay_ms)
      %{state | shutdown_ref: ref}
    else
      state
    end
  end

  defp cancel_shutdown(%{shutdown_ref: nil} = state), do: state

  defp cancel_shutdown(%{shutdown_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | shutdown_ref: nil}
  end
end
