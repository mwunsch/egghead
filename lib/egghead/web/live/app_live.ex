defmodule Egghead.Web.AppLive do
  use Egghead.Web, :live_view

  alias Egghead.Web.MarkdownHTML
  alias Egghead.TUI.Records.Slug

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Egghead.PubSub, Egghead.RecordStore.records_topic())
    end

    all = Egghead.list_records() |> Enum.sort_by(&(&1.updated || ""), :desc)
    selected_id = params["id"]
    room_id = Egghead.default_room()

    socket =
      socket
      |> assign(
        # Layout state
        nav_open: true,
        chat_open: true,
        # Nav state
        query: "",
        all: all,
        filtered: all,
        class_filter: MapSet.new([:durable, :inbox, :deliberation, :agent]),
        class_dropdown_open: false,
        nav_view: :search,
        # Record state
        selected_id: selected_id,
        selected_record: nil,
        selected_body_html: nil,
        backlinks: [],
        word_count: 0,
        # Chat state
        room_id: room_id,
        transcript: [],
        active_streams: %{},
        chat_status: nil,
        agents: []
      )
      |> apply_filter()
      |> hydrate_selection()
      |> hydrate_chat()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params["id"] do
      nil ->
        {:noreply,
         assign(socket,
           selected_id: nil,
           selected_record: nil,
           selected_body_html: nil,
           backlinks: [],
           word_count: 0
         )}

      id ->
        {:noreply, socket |> assign(selected_id: id) |> hydrate_selection()}
    end
  end

  # --- UI events ---

  @impl true
  def handle_event("toggle_nav", _, socket) do
    {:noreply, assign(socket, nav_open: !socket.assigns.nav_open)}
  end

  def handle_event("toggle_chat", _, socket) do
    {:noreply, assign(socket, chat_open: !socket.assigns.chat_open)}
  end

  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(query: query) |> apply_filter()}
  end

  def handle_event("select_record", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: "/?id=#{id}")}
  end

  def handle_event("toggle_class_dropdown", _, socket) do
    {:noreply, assign(socket, class_dropdown_open: !socket.assigns.class_dropdown_open)}
  end

  def handle_event("toggle_class", %{"class" => class}, socket) do
    class_atom = String.to_existing_atom(class)
    current = socket.assigns.class_filter

    updated =
      if MapSet.member?(current, class_atom),
        do: MapSet.delete(current, class_atom),
        else: MapSet.put(current, class_atom)

    {:noreply, socket |> assign(class_filter: updated) |> apply_filter()}
  end

  def handle_event("class_select_all", _, socket) do
    {:noreply,
     socket
     |> assign(class_filter: MapSet.new([:durable, :inbox, :deliberation, :agent]))
     |> apply_filter()}
  end

  def handle_event("class_select_none", _, socket) do
    {:noreply, socket |> assign(class_filter: MapSet.new()) |> apply_filter()}
  end

  def handle_event("switch_nav_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, nav_view: String.to_existing_atom(view))}
  end

  def handle_event("create_record", %{"title" => title}, socket) do
    slug = Slug.slugify(title)

    if slug != "" do
      case Egghead.create_record(%{id: slug, class: :durable, title: title}) do
        {:ok, _record} ->
          {:noreply, push_patch(socket, to: "/?id=#{slug}")}

        {:error, _reason} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("send_chat", %{"message" => message}, socket) do
    message = String.trim(message)

    cond do
      message == "" ->
        {:noreply, socket}

      message == "/continue" && socket.assigns.room_id ->
        Egghead.chat_continue(socket.assigns.room_id)
        {:noreply, socket}

      message == "/save" && socket.assigns.room_id ->
        Egghead.chat_save(socket.assigns.room_id)
        {:noreply, assign(socket, chat_status: "Transcript saved.")}

      socket.assigns.room_id ->
        Egghead.chat(socket.assigns.room_id, message)
        {:noreply, socket}

      true ->
        {:noreply, assign(socket, chat_status: "No chat room available.")}
    end
  end

  # --- PubSub: record changes ---

  @impl true
  def handle_info({:record_changed, _id}, socket) do
    all = Egghead.list_records() |> Enum.sort_by(&(&1.updated || ""), :desc)

    socket =
      socket
      |> assign(all: all)
      |> apply_filter()
      |> hydrate_selection()

    {:noreply, socket}
  end

  # --- PubSub: chat room events ---

  def handle_info({:user_message, msg}, socket) do
    entry = Egghead.TUI.Chat.Entry.user(msg.sender.name, msg.content)
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info({:agent_message, msg}, socket) do
    socket =
      socket
      |> finalize_stream(msg.sender.id)
      |> drop_stream(msg.sender.id)

    {:noreply, socket}
  end

  def handle_info({:agent_streaming, _room_id, agent_id, delta}, socket) do
    {:noreply, apply_stream_delta(socket, agent_id, delta)}
  end

  def handle_info({:agent_tool_call, _room_id, agent_id, name, input}, socket) do
    display = agent_display_name(agent_id)
    text = "#{name}(#{inspect(input, pretty: true, limit: 3)})"
    entry = Egghead.TUI.Chat.Entry.action(agent_id, display, text)
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info({:agents_activated, _count}, socket), do: {:noreply, socket}

  def handle_info({:agent_passed, agent_id}, socket) do
    {:noreply, drop_stream(socket, agent_id)}
  end

  def handle_info(:budget_exhausted, socket) do
    {:noreply,
     assign(socket, chat_status: "Budget exhausted \u2014 type /continue to grant more turns.")}
  end

  def handle_info(:continued, socket) do
    {:noreply, assign(socket, chat_status: nil)}
  end

  def handle_info({:agent_joined, agent_id}, socket) do
    entry = Egghead.TUI.Chat.Entry.system("#{agent_display_name(agent_id)} joined")
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info({:agent_left, agent_id}, socket) do
    entry = Egghead.TUI.Chat.Entry.system("#{agent_display_name(agent_id)} left")
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info({:agent_handoff, _room_id, agent_id, _delib_id}, socket) do
    entry = Egghead.TUI.Chat.Entry.system("#{agent_display_name(agent_id)} handed off context")
    {:noreply, append_entry(socket, entry)}
  end

  def handle_info({:agent_mentions, _room_id, _from, _to}, socket), do: {:noreply, socket}

  def handle_info({:system_notice, text}, socket) do
    {:noreply, append_entry(socket, Egghead.TUI.Chat.Entry.system(text))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # --- Private: records ---

  defp apply_filter(socket) do
    records = socket.assigns.all
    query = socket.assigns.query
    classes = socket.assigns.class_filter

    filtered =
      records
      |> filter_by_class(classes)
      |> filter_by_query(query)

    assign(socket, filtered: filtered)
  end

  defp filter_by_class(records, classes) do
    Enum.filter(records, &MapSet.member?(classes, &1.class))
  end

  defp filter_by_query(records, ""), do: records

  defp filter_by_query(records, query) do
    needle = String.downcase(query)

    Enum.filter(records, fn r ->
      String.contains?(String.downcase(r.id || ""), needle) or
        String.contains?(String.downcase(r.title || ""), needle)
    end)
  end

  defp creation_target(query, filtered) do
    title = String.trim(query)

    if title == "" do
      nil
    else
      slug = Slug.slugify(title)

      cond do
        slug == "" -> nil
        Enum.any?(filtered, &(&1.id == slug)) -> nil
        true -> {title, slug}
      end
    end
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

            backlinks = Egghead.find_backlinks(id)

            word_count =
              case record.body do
                nil -> 0
                body -> body |> String.split(~r/\s+/, trim: true) |> length()
              end

            assign(socket,
              selected_record: record,
              selected_body_html: html,
              backlinks: backlinks,
              word_count: word_count
            )

          {:error, _} ->
            assign(socket,
              selected_record: nil,
              selected_body_html: nil,
              backlinks: [],
              word_count: 0
            )
        end
    end
  end

  defp record_exists?(id) do
    case Egghead.get_record(id) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp build_file_tree(records) do
    records
    |> Enum.group_by(fn r ->
      case String.split(r.id || "", "/") do
        [_single] -> ""
        parts -> parts |> Enum.drop(-1) |> Enum.join("/")
      end
    end)
    |> Enum.sort_by(fn {dir, _} -> dir end)
  end

  # --- Private: chat ---

  defp hydrate_chat(socket) do
    case socket.assigns.room_id do
      nil ->
        socket

      room_id ->
        if connected?(socket) do
          Egghead.Chat.Room.subscribe(room_id)
        end

        transcript =
          case Egghead.Chat.Room.get_transcript(room_id) do
            {:ok, messages} ->
              Enum.map(messages, fn msg ->
                case msg.sender.type do
                  :user ->
                    Egghead.TUI.Chat.Entry.user(msg.sender.name, msg.content)

                  :agent ->
                    Egghead.TUI.Chat.Entry.agent(
                      msg.sender.id,
                      msg.sender.name,
                      msg.content
                    )
                end
              end)

            _ ->
              []
          end

        assign(socket, transcript: transcript)
    end
  end

  defp apply_stream_delta(socket, agent_id, delta) do
    current = socket.assigns.active_streams
    name = agent_display_name(agent_id)
    s = Map.get(current, agent_id, Egghead.TUI.Chat.Stream.new(agent_id, name))
    {s, committed} = Egghead.TUI.Chat.Stream.append(s, delta)

    socket
    |> assign(active_streams: Map.put(current, agent_id, s))
    |> append_entries(committed)
  end

  defp finalize_stream(socket, agent_id) do
    case Map.get(socket.assigns.active_streams, agent_id) do
      nil -> socket
      stream -> append_entries(socket, Egghead.TUI.Chat.Stream.finalize(stream))
    end
  end

  defp drop_stream(socket, agent_id) do
    assign(socket, active_streams: Map.delete(socket.assigns.active_streams, agent_id))
  end

  defp append_entry(socket, entry) do
    assign(socket, transcript: socket.assigns.transcript ++ [entry])
  end

  defp append_entries(socket, []), do: socket

  defp append_entries(socket, entries) do
    assign(socket, transcript: socket.assigns.transcript ++ entries)
  end

  defp agent_display_name(agent_id) do
    agent_id |> String.split("/") |> List.last() |> String.capitalize()
  end

  defp ghost_entries(streams) do
    streams
    |> Enum.filter(fn {_id, s} -> Egghead.TUI.Chat.Stream.has_text?(s) end)
    |> Enum.map(fn {_id, s} -> {s.name, s.current} end)
  end

  defp render_entry_html(%Egghead.TUI.Chat.Entry{text: text}) do
    MarkdownHTML.render(text)
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    phantom = creation_target(assigns.query, assigns.filtered)
    file_tree = if assigns.nav_view == :tree, do: build_file_tree(assigns.filtered), else: []

    assigns =
      assigns
      |> assign(:phantom, phantom)
      |> assign(:file_tree, file_tree)

    ~H"""
    <div class="app-shell">
      <header class="app-header">
        <div class="header-left">
          <button class="header-btn sidebar-toggle" phx-click="toggle_nav" title="Toggle navigation">
            <svg width="20" height="18" viewBox="0 0 20 18" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
              <rect x="2" y="2" width="16" height="14" rx="2" />
              <rect x="2" y="2" width="6" height="14" rx="2"
                fill={if @nav_open, do: "currentColor", else: "none"}
                stroke="currentColor"
              />
            </svg>
          </button>
          <span class="app-title">egghead</span>
        </div>
        <div class="header-center">
          <span :if={@selected_record} class="breadcrumb">{@selected_record.id}</span>
        </div>
        <div class="header-right">
          <button class="header-btn sidebar-toggle" phx-click="toggle_chat" title="Toggle chat">
            <svg width="20" height="18" viewBox="0 0 20 18" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
              <rect x="2" y="2" width="16" height="14" rx="2" />
              <rect x="12" y="2" width="6" height="14" rx="2"
                fill={if @chat_open, do: "currentColor", else: "none"}
                stroke="currentColor"
              />
            </svg>
          </button>
        </div>
      </header>

      <div class="app-body">
        <%!-- Left nav sidebar --%>
        <aside class={["nav-sidebar", !@nav_open && "collapsed"]}>
          <div class="nav-inner">
            <div class="nav-toolbar">
              <button
                class={["toolbar-btn", @nav_view == :tree && "toggled"]}
                phx-click="switch_nav_view"
                phx-value-view={if @nav_view == :tree, do: "search", else: "tree"}
              >
                <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
                  <path d="M2 2h4v4H2zM8 3h6M8 7h4M2 10h4v4H2zM8 11h6" />
                </svg>
                <span class="toolbar-label">Tree</span>
              </button>
              <div class="toolbar-spacer"></div>
              <div class="class-filter-wrap">
                <button
                  class="toolbar-btn"
                  phx-click="toggle_class_dropdown"
                >
                  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M1 3h14M3 8h10M5 13h6" />
                  </svg>
                  <span class="toolbar-label">Filter</span>
                </button>
                <div :if={@class_dropdown_open} class="class-dropdown">
                  <div class="dropdown-actions">
                    <button class="dropdown-link" phx-click="class_select_all">All</button>
                    <button class="dropdown-link" phx-click="class_select_none">None</button>
                  </div>
                  <label :for={c <- [:durable, :agent, :deliberation, :inbox]} class="class-option">
                    <input
                      type="checkbox"
                      checked={MapSet.member?(@class_filter, c)}
                      phx-click="toggle_class"
                      phx-value-class={c}
                    />
                    {c}
                  </label>
                </div>
              </div>
            </div>
            <div class="nav-search">
              <form phx-change="search" phx-submit={if @phantom, do: "create_record", else: "search"}>
                <input
                  type="text"
                  name="query"
                  value={@query}
                  placeholder="Search or create..."
                  autocomplete="off"
                  phx-debounce="100"
                />
                <input :if={@phantom} type="hidden" name="title" value={elem(@phantom, 0)} />
              </form>
            </div>

            <%!-- Record list --%>
            <div class="record-list-wrap">
              <%!-- List view --%>
              <ul :if={@nav_view == :search} class="record-list">
                <li
                  :for={record <- @filtered}
                  class={["record-item", record.id == @selected_id && "selected"]}
                  phx-click="select_record"
                  phx-value-id={record.id}
                >
                  <span class="record-title">{record.title || record.id}</span>
                  <span class="record-meta">{record.class}</span>
                </li>
                <li
                  :if={@phantom}
                  class="record-item phantom"
                  phx-click="create_record"
                  phx-value-title={elem(@phantom, 0)}
                >
                  <span class="record-title">Create "{elem(@phantom, 0)}"</span>
                  <span class="record-meta">{elem(@phantom, 1)}</span>
                </li>
              </ul>

              <%!-- Tree view --%>
              <ul :if={@nav_view == :tree} class="record-list file-tree">
                <li :for={{dir, records} <- @file_tree} class="tree-group">
                  <div :if={dir != ""} class="tree-dir">{dir}/</div>
                  <ul>
                    <li
                      :for={record <- records}
                      class={["record-item", record.id == @selected_id && "selected"]}
                      phx-click="select_record"
                      phx-value-id={record.id}
                    >
                      <span class="record-title">
                        {record.title || List.last(String.split(record.id, "/"))}
                      </span>
                    </li>
                  </ul>
                </li>
              </ul>
            </div>
          </div>
        </aside>

        <%!-- Center: record body --%>
        <main class="record-pane">
          <div :if={@selected_record} class="record-content">
            <div class="properties-block">
              <h1 class="record-heading">{@selected_record.title || @selected_record.id}</h1>
              <dl class="properties">
                <div class="prop-row">
                  <dt>id</dt>
                  <dd class="prop-id">{@selected_record.id}</dd>
                </div>
                <div :if={@selected_record.created} class="prop-row">
                  <dt>created</dt>
                  <dd>{@selected_record.created}</dd>
                </div>
                <div :if={@selected_record.updated} class="prop-row">
                  <dt>updated</dt>
                  <dd>{@selected_record.updated}</dd>
                </div>
                <div :if={@selected_record.author} class="prop-row">
                  <dt>author</dt>
                  <dd>{@selected_record.author}</dd>
                </div>
                <div :if={@selected_record.tags != []} class="prop-row">
                  <dt>tags</dt>
                  <dd>
                    <span :for={tag <- @selected_record.tags} class="tag-pill">{tag}</span>
                  </dd>
                </div>
                <div :if={@selected_record.links != []} class="prop-row">
                  <dt>links</dt>
                  <dd>
                    <a
                      :for={link <- @selected_record.links}
                      class="prop-link"
                      href={"/?id=#{link}"}
                      data-phx-link="patch"
                      data-phx-link-state="push"
                    >
                      {link}
                    </a>
                  </dd>
                </div>
                <div class="prop-row">
                  <dt>class</dt>
                  <dd><span class={"class-badge #{@selected_record.class}"}>{@selected_record.class}</span></dd>
                </div>
              </dl>
              <div class="properties-actions">
                <button
                  class="btn-chrome"
                  id="copy-md-btn"
                  phx-hook="CopyMarkdown"
                  data-markdown={@selected_record.body || ""}
                >
                  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
                    <rect x="5" y="5" width="9" height="9" rx="1" />
                    <path d="M3 11V3a1 1 0 0 1 1-1h8" />
                  </svg>
                  <span class="btn-label">Copy</span>
                </button>
              </div>
            </div>
            <article class="record-body markdown-body">
              {Phoenix.HTML.raw(@selected_body_html)}
            </article>
          </div>
          <div :if={!@selected_record} class="empty-state">
            <p>Select a record to begin.</p>
          </div>
        </main>

        <%!-- Status bar --%>
        <div :if={@selected_record} class="record-status-bar">
          <span class="status-cell">{length(@backlinks)} backlinks</span>
          <span class="status-cell">{@word_count} words</span>
          <span class="status-cell">{@selected_record.class}</span>
        </div>

        <%!-- Right: chat sidebar --%>
        <aside class={["chat-sidebar", !@chat_open && "collapsed"]}>
          <div class="chat-inner">
            <div class="chat-header">
              <span class="chat-title">Chat</span>
              <span :if={@room_id} class="room-id">{@room_id}</span>
            </div>
            <div class="chat-transcript" id="chat-transcript" phx-hook="ScrollBottom">
              <div
                :for={entry <- @transcript}
                class={["chat-entry", "entry-#{entry.kind}"]}
              >
                <span :if={entry.sender_name} class="nick">{entry.sender_name}</span>
                <span :if={entry.timestamp} class="time">
                  {Calendar.strftime(entry.timestamp, "%H:%M")}
                </span>
                <span class="entry-body">{Phoenix.HTML.raw(render_entry_html(entry))}</span>
              </div>
              <div
                :for={{name, text} <- ghost_entries(@active_streams)}
                class="chat-entry entry-agent ghost"
              >
                <span class="nick">{name}</span>
                <span class="entry-body">{text}</span>
              </div>
            </div>
            <div :if={@chat_status} class="chat-status">{@chat_status}</div>
            <form phx-submit="send_chat" class="chat-input">
              <textarea
                id="chat-textarea"
                name="message"
                placeholder={if @room_id, do: "Type a message...", else: "No room"}
                autocomplete="off"
                disabled={is_nil(@room_id)}
                rows="1"
                phx-hook="ChatInput"
              ></textarea>
            </form>
          </div>
        </aside>
      </div>
    </div>
    """
  end
end
