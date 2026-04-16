defmodule Egghead.Web.DocChannel do
  use Phoenix.Channel

  alias Egghead.Doc.Server

  @impl true
  def join("doc:" <> record_id, _params, socket) do
    case Server.ensure_started(record_id) do
      {:ok, _pid} ->
        socket = assign(socket, :record_id, record_id)
        send(self(), :after_join)
        {:ok, socket}

      {:error, reason} ->
        {:error, %{reason: inspect(reason)}}
    end
  end

  @impl true
  def handle_in("update", %{"data" => encoded}, socket) do
    update = Base.decode64!(encoded)
    Server.apply_update(socket.assigns.record_id, update)
    {:noreply, socket}
  end

  def handle_in("awareness", %{"data" => encoded}, socket) do
    broadcast_from!(socket, "awareness", %{data: encoded})
    {:noreply, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    case Server.attach(socket.assigns.record_id, self()) do
      {:ok, initial_state} ->
        push(socket, "sync", %{data: Base.encode64(initial_state)})

      {:error, _} ->
        :ok
    end

    {:noreply, socket}
  end

  def handle_info({:doc_update, {:yjs_update, update}}, socket) do
    push(socket, "update", %{data: Base.encode64(update)})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if record_id = socket.assigns[:record_id] do
      Server.detach(record_id, self())
    end

    :ok
  end
end
