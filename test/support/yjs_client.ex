defmodule Egghead.Test.YjsClient do
  @moduledoc """
  Simulates a browser Yjs client for testing Doc.Server.

  Each client holds its own Yex.Doc. It attaches to a Doc.Server,
  applies the initial state, and can make local edits. After each
  edit, it computes the update diff and sends it to the server.
  Remote updates from the server are applied to the local doc.
  """

  use GenServer

  defstruct [:record_id, :doc, :text, :owner, :last_sv]

  def start_link(record_id, owner_pid) do
    GenServer.start_link(__MODULE__, {record_id, owner_pid})
  end

  def start(record_id, owner_pid) do
    GenServer.start(__MODULE__, {record_id, owner_pid})
  end

  def connect(pid), do: GenServer.call(pid, :connect)
  def insert(pid, index, content), do: GenServer.call(pid, {:insert, index, content})
  def delete(pid, index, length), do: GenServer.call(pid, {:delete, index, length})
  def read(pid), do: GenServer.call(pid, :read)

  @impl true
  def init({record_id, owner_pid}) do
    doc = Yex.Doc.new()
    text = Yex.Doc.get_text(doc, "content")

    state = %__MODULE__{record_id: record_id, doc: doc, text: text, owner: owner_pid}
    {:ok, state}
  end

  @impl true
  def handle_call(:connect, _from, state) do
    case Egghead.Doc.Server.ensure_started(state.record_id) do
      {:ok, _} ->
        {:ok, initial} = Egghead.Doc.Server.attach(state.record_id, self())
        Yex.apply_update(state.doc, initial)
        {:ok, sv} = Yex.encode_state_vector(state.doc)
        {:reply, :ok, %{state | last_sv: sv}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:insert, index, content}, _from, state) do
    {:ok, sv_before} = Yex.encode_state_vector(state.doc)
    Yex.Text.insert(state.text, index, content)
    {:ok, update} = Yex.encode_state_as_update(state.doc, sv_before)
    Egghead.Doc.Server.apply_update(state.record_id, update)
    {:ok, sv} = Yex.encode_state_vector(state.doc)
    {:reply, :ok, %{state | last_sv: sv}}
  end

  def handle_call({:delete, index, length}, _from, state) do
    {:ok, sv_before} = Yex.encode_state_vector(state.doc)
    Yex.Text.delete(state.text, index, length)
    {:ok, update} = Yex.encode_state_as_update(state.doc, sv_before)
    Egghead.Doc.Server.apply_update(state.record_id, update)
    {:ok, sv} = Yex.encode_state_vector(state.doc)
    {:reply, :ok, %{state | last_sv: sv}}
  end

  def handle_call(:read, _from, state) do
    {:reply, Yex.Text.to_string(state.text), state}
  end

  @impl true
  def handle_info({:doc_update, {:yjs_update, update}}, state) do
    Yex.apply_update(state.doc, update)
    send(state.owner, {:client_updated, self()})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
