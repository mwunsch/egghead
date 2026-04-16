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
