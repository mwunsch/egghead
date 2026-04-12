defmodule Egghead.Web.RecordsLive do
  use Egghead.Web, :live_view

  alias Egghead.Web.MarkdownHTML

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Egghead.PubSub, Egghead.RecordStore.records_topic())
    end

    all = Egghead.list_records() |> Enum.sort_by(&(&1.updated || ""), :desc)

    selected_id = params["id"]

    socket =
      socket
      |> assign(
        query: "",
        all: all,
        filtered: all,
        selected_id: selected_id,
        selected_record: nil,
        selected_body_html: nil
      )
      |> hydrate_selection()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params["id"] do
      nil ->
        {:noreply,
         assign(socket, selected_id: nil, selected_record: nil, selected_body_html: nil)}

      id ->
        {:noreply, socket |> assign(selected_id: id) |> hydrate_selection()}
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    filtered = filter_records(socket.assigns.all, query)
    {:noreply, assign(socket, query: query, filtered: filtered)}
  end

  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: "/?id=#{id}")}
  end

  @impl true
  def handle_info({:record_changed, _id}, socket) do
    all = Egghead.list_records() |> Enum.sort_by(&(&1.updated || ""), :desc)
    filtered = filter_records(all, socket.assigns.query)

    socket =
      socket
      |> assign(all: all, filtered: filtered)
      |> hydrate_selection()

    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp filter_records(records, ""), do: records

  defp filter_records(records, query) do
    needle = String.downcase(query)

    Enum.filter(records, fn r ->
      String.contains?(String.downcase(r.id || ""), needle) or
        String.contains?(String.downcase(r.title || ""), needle)
    end)
  end

  defp hydrate_selection(socket) do
    case socket.assigns.selected_id do
      nil ->
        socket

      id ->
        case Egghead.get_record(id) do
          {:ok, record} ->
            html =
              MarkdownHTML.render(record.body || "",
                link_fn: &"/?id=#{&1}",
                exists_fn: &record_exists?/1
              )

            assign(socket, selected_record: record, selected_body_html: html)

          {:error, _} ->
            assign(socket, selected_record: nil, selected_body_html: nil)
        end
    end
  end

  defp record_exists?(id) do
    case Egghead.get_record(id) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="records-layout">
      <div class="records-sidebar">
        <div class="records-search">
          <form phx-change="search" phx-submit="search">
            <input
              type="text"
              name="query"
              value={@query}
              placeholder="Search records..."
              autocomplete="off"
              phx-debounce="150"
            />
          </form>
        </div>
        <ul class="records-list">
          <li
            :for={record <- @filtered}
            class={["record-item", record.id == @selected_id && "selected"]}
            phx-click="select"
            phx-value-id={record.id}
          >
            <span class="record-title">{record.title || record.id}</span>
            <span class="record-class">{record.class}</span>
          </li>
        </ul>
      </div>
      <div class="records-preview">
        <div :if={@selected_record} class="preview-content">
          <h1 class="preview-title">{@selected_record.title || @selected_record.id}</h1>
          <div :if={@selected_record.tags != []} class="preview-tags">
            <span :for={tag <- @selected_record.tags} class="tag">{tag}</span>
          </div>
          <div class="preview-body">
            {Phoenix.HTML.raw(@selected_body_html)}
          </div>
        </div>
        <div :if={!@selected_record} class="preview-empty">
          <p>Select a record to preview</p>
        </div>
      </div>
    </div>
    """
  end
end
