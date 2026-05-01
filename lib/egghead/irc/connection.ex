defmodule Egghead.IRC.Connection do
  @moduledoc """
  Per-connection IRC handler. One process per TCP socket.

  Owns the connection state (registration status, nick, joined channels,
  PubSub subscriptions) and translates between two halves of the world:

  - **Inbound**: bytes from the socket → `Egghead.IRC.Protocol.chunk/2` →
    a `%Message{}` per line → `dispatch/2` → call into `Egghead.Chat.Room`
    or reply directly with a numeric.
  - **Outbound**: room PubSub events (`{:user_message, msg}`,
    `{:agent_message, msg}`, `{:agent_joined, id}`, …) → IRC wire lines
    written back to the socket.

  Implements `ThousandIsland.Handler`, which gives us `handle_connection/2`,
  `handle_data/3`, `handle_close/2`, plus regular `GenServer.handle_info/2`
  for PubSub messages.
  """

  use ThousandIsland.Handler

  require Logger

  alias Egghead.IRC.{Protocol, Numerics, NickMap, Registry, Server}
  alias Egghead.Chat.Room

  @pubsub Egghead.PubSub

  # Server-side keepalive. Every `@ping_interval` ms we send a fresh
  # PING to the client; the client must PONG back before the *next*
  # tick fires or we close the connection. Without this, an idle ERC
  # session would silently drop after Thousand Island's default 60s
  # read_timeout — clean close, no log, ERC re-establishes the
  # socket every minute.
  @ping_interval 90_000

  # IRCv3 capabilities the server advertises.
  #
  # - `server-time` lets clients render messages at the timestamp the
  #   server emits (not "now") — what makes scrollback feel real.
  # - `batch` lets us wrap multi-message bursts (CHATHISTORY responses)
  #   in a `BATCH +id chathistory ...` ... `BATCH -id` envelope so
  #   clients distinguish history from live traffic.
  # - `chathistory` advertises that the server understands the
  #   `CHATHISTORY` verb (LATEST / BEFORE / AFTER / AROUND / BETWEEN).
  @supported_caps ["server-time", "batch", "chathistory"]

  # How many recent transcript messages to replay into a client's
  # scrollback when they JOIN a channel — only sent if the client
  # negotiated `server-time`, otherwise the messages would render at
  # "now" and look like a confusing burst of duplicates.
  @history_replay_count 50

  # Cap on the number of messages a single CHATHISTORY query may return.
  # Advertised in ISUPPORT as `CHATHISTORY=<limit>`. Clients clamp
  # their requests to this; we clamp again on the server side as
  # defense in depth.
  @chathistory_max 100

  # --- ThousandIsland.Handler callbacks ---

  @impl ThousandIsland.Handler
  def handle_connection(socket, _state) do
    cfg = Server.config()

    peer =
      case ThousandIsland.Socket.peername(socket) do
        {:ok, {ip, port}} -> "#{:inet.ntoa(ip)}:#{port}"
        _ -> "?"
      end

    Logger.info("IRC: connection opened from #{peer}")

    state = %{
      server: cfg.hostname,
      version: cfg.version,
      created_at: cfg.created_at,
      password_required: not is_nil(cfg.password),
      password: cfg.password,
      password_ok: is_nil(cfg.password),
      registered: false,
      buffer: "",
      nick: nil,
      user: nil,
      realname: nil,
      channels: MapSet.new(),
      cap_negotiating: false,
      # Per-room PubSub forwarder Tasks. Maps room_id -> task pid.
      # Task subscribes to `room:#{room_id}` and forwards each message
      # back to us tagged `{:room_event, room_id, original}` — that's
      # how the connection learns which room each event came from
      # (Phoenix.PubSub doesn't expose the topic in handle_info).
      routers: %{},
      # Per-(room, agent) streaming buffer. Tracks the cumulative text
      # already emitted so we can mid-stream flush completed paragraphs
      # as PRIVMSGs and emit the unflushed tail on the final
      # :agent_message without doubling content.
      streams: %{},
      # Per-connection channel-name aliases. When a user joins via
      # `#default` we route to the canonical room id but echo JOIN /
      # NAMES / PRIVMSG / actions back with the alias the client typed
      # — strict clients (ERC) won't open a buffer when the JOIN echo
      # references a different channel name than the request. Map shape:
      # `%{room_id => "#alias-they-typed"}`.
      aliases: %{},
      # Server-initiated keepalive state. `awaiting_pong?` is set when
      # we send a PING and cleared when the matching PONG arrives.
      # If the next tick fires while still awaiting, the connection
      # is dead — close it.
      awaiting_pong?: false,
      # IRCv3 capabilities the client has negotiated. Determines
      # whether outbound messages get `@time=` tags and whether JOIN
      # replays scrollback from the room transcript.
      caps: MapSet.new()
    }

    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    {messages, buffer} = Protocol.chunk(state.buffer, data)
    state = %{state | buffer: buffer}

    Enum.reduce_while(messages, {:continue, state}, fn msg, {:continue, st} ->
      case dispatch(msg, Map.put(st, :__socket__, socket)) do
        {:continue, st2} -> {:cont, {:continue, drop_socket(st2)}}
        {:close, st2} -> {:halt, {:close, drop_socket(st2)}}
      end
    end)
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    Logger.info("IRC: connection closed (nick=#{state.nick || "*"})")
    cleanup(state)
    :ok
  end

  @impl ThousandIsland.Handler
  def handle_error(reason, _socket, state) do
    Logger.info("IRC: connection error (nick=#{state.nick || "*"}, reason=#{inspect(reason)})")
    cleanup(state)
    :ok
  end

  # PubSub messages and other system messages route through GenServer
  # handle_info; ThousandIsland passes them through unchanged. The
  # callback receives `{socket, state}` and returns the same shape.

  # Per-room router task forwards every PubSub event from `room:#{room_id}`
  # tagged with the room_id it came from — that's how we route correctly
  # when this connection is in multiple rooms simultaneously.
  def handle_info({:room_event, room_id, msg}, {socket, state}) do
    state = handle_room_event(msg, room_id, socket, state)
    {:noreply, {socket, state}}
  end

  # Keepalive tick. If the client never PONG'd back the previous PING,
  # they're dead — close the socket. Otherwise send a fresh PING and
  # re-arm.
  def handle_info(:keepalive_tick, {socket, %{awaiting_pong?: true} = state}) do
    Logger.info("IRC: dropping #{state.nick || "*"} — no PONG within #{@ping_interval}ms")
    cleanup(state)
    {:stop, :normal, {socket, state}}
  end

  def handle_info(:keepalive_tick, {socket, state}) do
    Logger.info("IRC: -> PING (#{state.nick || "*"})")

    send_line(
      socket,
      Protocol.encode(prefix: state.server, command: "PING", trailing: state.server)
    )

    schedule_keepalive()
    {:noreply, {socket, %{state | awaiting_pong?: true}}}
  end

  def handle_info(_other, {socket, state}) do
    {:noreply, {socket, state}}
  end

  defp schedule_keepalive do
    Process.send_after(self(), :keepalive_tick, @ping_interval)
  end

  # --- Room event dispatch ---
  #
  # Every event the room (or coordinator) broadcasts on `room:#{room_id}`
  # lands here once via the router. Each clause renders to the IRC wire:
  # PRIVMSG for messages, NOTICE for system text, JOIN/PART for roster,
  # CTCP ACTION for /pass, tool calls, and other atmospheric lines.

  # User chat — suppress own echo (see own_user_message?/2).
  defp handle_room_event({:user_message, msg}, room_id, socket, state) do
    unless own_user_message?(msg, state) do
      send_privmsg(socket, state, msg.sender.name, room_id, msg.content)
    end

    state
  end

  # Final agent message. If we already streamed paragraphs of this turn,
  # the stream buffer tells us how much we've emitted; only the suffix
  # goes out as a fresh PRIVMSG.
  defp handle_room_event({:agent_message, msg}, room_id, socket, state) do
    nick = NickMap.id_to_nick(msg.sender.id)
    {tail, state} = take_stream_tail(state, room_id, msg.sender.id, msg.content)

    if tail != "" do
      send_privmsg(socket, state, nick, room_id, tail)
    end

    state
  end

  # Mid-stream token deltas — accumulate per-(room, agent), flush
  # whole paragraphs (split on `\n\n`) as PRIVMSGs as they complete,
  # keep the trailing partial buffered until the next chunk or the
  # final :agent_message.
  defp handle_room_event({:agent_streaming, _room_id, agent_id, delta}, room_id, socket, state) do
    nick = NickMap.id_to_nick(agent_id)
    {to_emit, state} = absorb_stream_chunk(state, room_id, agent_id, delta)

    if to_emit != "" do
      send_privmsg(socket, state, nick, room_id, to_emit)
    end

    state
  end

  # /pass — atmospheric action line. Each renderer picks its own flavor
  # from PassActions; the TUI does the same and may pick a different
  # phrase. That's intentional, not a bug.
  defp handle_room_event({:agent_passed, agent_id}, room_id, socket, state) do
    nick = NickMap.id_to_nick(agent_id)
    flavor = Egghead.Chat.PassActions.pick()
    send_action(socket, state, nick, room_id, flavor)
    state
  end

  # Tool call — rendered as `*scout uses read_file path=foo.md*`,
  # mirroring the TUI format (key=value pairs, values truncated to ~40
  # chars to keep the line readable).
  defp handle_room_event(
         {:agent_tool_call, _room_id, agent_id, name, input},
         room_id,
         socket,
         state
       ) do
    nick = NickMap.id_to_nick(agent_id)
    summary = "uses #{name}#{format_tool_input(input)}"
    send_action(socket, state, nick, room_id, summary)
    state
  end

  # Tool denied by the capability layer — rendered as a CTCP ACTION
  # so it reads alongside the tool-call line. The denial's `message`
  # field is the human-readable reason (e.g. "no grant for net.get on
  # api.example.com"); we don't surface the structured request/grants
  # — those live in the log for operators.
  defp handle_room_event(
         {:agent_tool_denied, _room_id, agent_id, tool_name, _input, denial},
         room_id,
         socket,
         state
       ) do
    nick = NickMap.id_to_nick(agent_id)
    reason = (denial && Map.get(denial, :message)) || "denied"
    send_action(socket, state, nick, room_id, "was denied #{tool_name}: #{reason}")
    state
  end

  # Roster change — emit synthetic JOIN/PART so the IRC client's
  # nicklist updates live without needing a fresh /NAMES query, then
  # push a TOPIC update so the channel header reflects the new count.
  defp handle_room_event({:agent_joined, agent_id}, room_id, socket, state) do
    nick = NickMap.id_to_nick(agent_id)
    channel = display_channel(state, room_id)
    line = Protocol.encode(prefix: agent_prefix(nick, state), command: "JOIN", params: [channel])
    send_line(socket, line)
    push_topic_update(socket, state, room_id)
    state
  end

  defp handle_room_event({:agent_left, agent_id}, room_id, socket, state) do
    nick = NickMap.id_to_nick(agent_id)
    channel = display_channel(state, room_id)
    line = Protocol.encode(prefix: agent_prefix(nick, state), command: "PART", params: [channel])
    send_line(socket, line)
    push_topic_update(socket, state, room_id)
    state
  end

  # Coordinator system notices — mute toggles, agent lifecycle, errors.
  # IRC NOTICE is the right wire form: most clients render NOTICEs
  # distinctly from PRIVMSG, which matches the TUI's dimmed gutter.
  defp handle_room_event({:system_notice, text}, room_id, socket, state) do
    send_notice(socket, state, room_id, text)
    state
  end

  # User halted the room (Ctrl-C in TUI, /halt in chat) — surface as a
  # NOTICE so the IRC operator sees that agents are no longer responding
  # without us hijacking the channel topic.
  defp handle_room_event({:halted, _room_id}, room_id, socket, state) do
    send_notice(socket, state, room_id, "Halted. Send another message to continue.")
    state
  end

  defp handle_room_event({:continued, opts}, room_id, socket, state) do
    text =
      case Keyword.get(opts, :replayed, 0) do
        0 -> "The room is quiet."
        n -> "Continuing — #{n} queued activation(s) replayed."
      end

    send_notice(socket, state, room_id, text)
    state
  end

  # Mute / unmute already comes through as :system_notice from the room
  # ("Scout muted"/"Scout unmuted"); the explicit :muted_changed event
  # is for sidebar UIs to flip an indicator. Nothing to render here.
  defp handle_room_event({:muted_changed, _agent_id, _muted?}, _room_id, _socket, state),
    do: state

  # Room shutdown — NOTICE the channel and tear down our subscription.
  defp handle_room_event({:room_stopped, _room_id}, room_id, socket, state) do
    send_notice(socket, state, room_id, "Room stopped")
    drop_room(state, room_id)
  end

  # Infrastructure-level events the IRC layer doesn't surface:
  # roster_changed (we synthesize JOIN/PART instead), agents_activated,
  # agent_mentions (coordinator-internal), reactivate, budget_exhausted,
  # tool_output (verbose, low signal).
  defp handle_room_event(_other, _room_id, _socket, state), do: state

  # --- Streaming buffer ---

  # Append `delta` to the per-(room, agent) buffer and return any
  # complete paragraphs ready to flush. Keeps the trailing partial
  # buffered until either more text completes a paragraph or the final
  # :agent_message arrives.
  defp absorb_stream_chunk(state, room_id, agent_id, delta) do
    key = {room_id, agent_id}
    buffer = (state.streams[key] || %{buffer: "", emitted: 0}).buffer
    combined = buffer <> delta

    case last_paragraph_break(combined) do
      nil ->
        new_streams =
          Map.put(state.streams, key, %{buffer: combined, emitted: stream_emitted(state, key)})

        {"", %{state | streams: new_streams}}

      cut ->
        to_emit = binary_part(combined, 0, cut)
        rest = binary_part(combined, cut + 2, byte_size(combined) - cut - 2)

        emitted = stream_emitted(state, key) + cut + 2
        new_streams = Map.put(state.streams, key, %{buffer: rest, emitted: emitted})
        {to_emit, %{state | streams: new_streams}}
    end
  end

  # On final :agent_message, return any text the streaming path didn't
  # emit and clear the per-(room, agent) state. Idempotent — if there
  # was no streaming for this turn, returns the entire content.
  defp take_stream_tail(state, room_id, agent_id, full_content) do
    key = {room_id, agent_id}

    case Map.get(state.streams, key) do
      nil ->
        {full_content, state}

      %{emitted: emitted} ->
        tail =
          if emitted < byte_size(full_content) do
            binary_part(full_content, emitted, byte_size(full_content) - emitted)
          else
            ""
          end

        {tail, %{state | streams: Map.delete(state.streams, key)}}
    end
  end

  defp stream_emitted(state, key) do
    case Map.get(state.streams, key) do
      nil -> 0
      %{emitted: e} -> e
    end
  end

  # Find the *last* "\n\n" boundary in a buffer — that's how far we can
  # safely flush as completed paragraphs. Returns the byte offset of the
  # first `\n` of the boundary, or nil if none found.
  defp last_paragraph_break(text) do
    case :binary.matches(text, "\n\n") do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  # --- Tool call formatting ---

  # Mirror the TUI: "uses TOOL key=value key=value" with values
  # truncated to keep lines short. Empty input → just the tool name.
  defp format_tool_input(nil), do: ""
  defp format_tool_input(input) when input == %{}, do: ""

  defp format_tool_input(input) when is_map(input) do
    pairs =
      input
      |> Enum.map(fn {k, v} -> "#{k}=#{truncate_tool_value(v)}" end)
      |> Enum.join(" ")

    if pairs == "", do: "", else: " " <> pairs
  end

  defp format_tool_input(_other), do: ""

  defp truncate_tool_value(v) when is_binary(v) do
    cleaned = v |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(cleaned) > 40, do: String.slice(cleaned, 0, 37) <> "...", else: cleaned
  end

  defp truncate_tool_value(v), do: v |> inspect() |> truncate_tool_value()

  # --- Wire helpers for actions / notices ---

  # Wraps text in CTCP ACTION delimiters (\x01ACTION ...\x01). Most IRC
  # clients render these as `* nick text` (the `/me` line style).
  defp send_action(socket, state, nick, room_id, text) do
    send_line(
      socket,
      Protocol.encode(
        tags: time_tag(state),
        prefix: nick,
        command: "PRIVMSG",
        params: [display_channel(state, room_id)],
        trailing: <<1>> <> "ACTION " <> text <> <<1>>
      )
    )

    state
  end

  defp send_notice(socket, state, room_id, text) do
    channel = display_channel(state, room_id)
    tags = time_tag(state)

    text
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(fn line ->
      send_line(
        socket,
        Protocol.encode(
          tags: tags,
          prefix: state.server,
          command: "NOTICE",
          params: [channel],
          trailing: line
        )
      )
    end)

    state
  end

  # Synthetic prefix for events sourced from agents (no real socket).
  # `nick!egghead@server` is recognizable, validates as a hostmask, and
  # makes it clear this isn't a human peer.
  defp agent_prefix(nick, state), do: "#{nick}!egghead@#{state.server}"

  # IRCv3 `server-time` tag. Returns `%{}` if the client didn't
  # negotiate the cap (so the encoder emits no tag prefix at all),
  # else `%{"time" => ISO-8601}`. Pass an explicit `DateTime` for
  # historical messages (scrollback replay); otherwise defaults to now.
  defp time_tag(state, dt \\ nil) do
    if MapSet.member?(state.caps, "server-time") do
      iso = (dt || DateTime.utc_now()) |> DateTime.to_iso8601()
      %{"time" => iso}
    else
      %{}
    end
  end

  # --- Command dispatch ---

  # We tuck the live socket into the state map for the duration of a
  # dispatch call so the per-command handlers don't all need an extra
  # arg. Stripped before returning.
  defp drop_socket(state), do: Map.delete(state, :__socket__)

  defp dispatch(%Protocol.Message{command: cmd} = msg, state) do
    case cmd do
      "CAP" ->
        handle_cap(msg, state)

      "PASS" ->
        handle_pass(msg, state)

      "NICK" ->
        handle_nick(msg, state)

      "USER" ->
        handle_user(msg, state)

      "PING" ->
        handle_ping(msg, state)

      "PONG" ->
        Logger.info("IRC: <- PONG (#{state.nick || "*"})")
        {:continue, %{state | awaiting_pong?: false}}

      "QUIT" ->
        handle_quit(msg, state)

      "JOIN" ->
        require_registered(state, fn -> handle_join(msg, state) end)

      "PART" ->
        require_registered(state, fn -> handle_part(msg, state) end)

      "PRIVMSG" ->
        require_registered(state, fn -> handle_privmsg(msg, state) end)

      "NAMES" ->
        require_registered(state, fn -> handle_names(msg, state) end)

      "MODE" ->
        require_registered(state, fn -> handle_mode(msg, state) end)

      "LIST" ->
        require_registered(state, fn -> handle_list(msg, state) end)

      # Egghead verbs — TUI slash-command palette over the IRC wire.
      # ERC's `/handoff scout` sends `HANDOFF scout`; users get the
      # exact muscle memory they have in the TUI.
      "HANDOFF" ->
        require_registered(state, fn -> handle_handoff(msg, state) end)

      "SAVE" ->
        require_registered(state, fn -> handle_save(msg, state) end)

      "CONTINUE" ->
        require_registered(state, fn -> handle_continue_cmd(msg, state) end)

      "HALT" ->
        require_registered(state, fn -> handle_halt(msg, state) end)

      "MUTE" ->
        require_registered(state, fn -> handle_mute(msg, state) end)

      "UNMUTE" ->
        require_registered(state, fn -> handle_unmute(msg, state) end)

      "CONTEXT" ->
        require_registered(state, fn -> handle_context(msg, state) end)

      "KICK" ->
        require_registered(state, fn -> handle_kick(msg, state) end)

      "INVITE" ->
        require_registered(state, fn -> handle_invite(msg, state) end)

      "WHOIS" ->
        require_registered(state, fn -> handle_whois(msg, state) end)

      "MOTD" ->
        require_registered(state, fn -> handle_motd(msg, state) end)

      "VERSION" ->
        require_registered(state, fn -> handle_version(msg, state) end)

      "TIME" ->
        require_registered(state, fn -> handle_time(msg, state) end)

      "CHATHISTORY" ->
        require_registered(state, fn -> handle_chathistory(msg, state) end)

      _ ->
        handle_unknown(msg, state)
    end
  end

  defp require_registered(%{registered: true}, fun), do: fun.()

  defp require_registered(state, _fun) do
    reply(state, Numerics.not_registered(state.server))
    {:continue, state}
  end

  # --- Registration ---

  defp handle_cap(msg, state) do
    case Protocol.Message.args(msg) do
      ["LS" | _] ->
        # Advertise supported capabilities. Clients that don't care
        # about CAP can ignore this; clients negotiating IRCv3 features
        # will pick a subset and CAP REQ them.
        reply(
          state,
          %Protocol.Message{
            prefix: state.server,
            command: "CAP",
            params: [nick_or_star(state), "LS"],
            trailing: Enum.join(@supported_caps, " ")
          }
        )

        {:continue, %{state | cap_negotiating: true}}

      ["REQ", req_caps] ->
        requested = String.split(req_caps, " ", trim: true)
        unsupported = Enum.reject(requested, &(&1 in @supported_caps))

        if unsupported == [] do
          new_caps =
            Enum.reduce(requested, state.caps, fn cap, acc -> MapSet.put(acc, cap) end)

          reply(
            state,
            %Protocol.Message{
              prefix: state.server,
              command: "CAP",
              params: [nick_or_star(state), "ACK"],
              trailing: req_caps
            }
          )

          {:continue, %{state | caps: new_caps}}
        else
          # Per IRCv3, REQ is atomic: NAK the whole batch if any single
          # cap is unsupported — partial acceptance breaks expectations.
          reply(
            state,
            %Protocol.Message{
              prefix: state.server,
              command: "CAP",
              params: [nick_or_star(state), "NAK"],
              trailing: req_caps
            }
          )

          {:continue, state}
        end

      ["END" | _] ->
        {:continue, maybe_complete_registration(%{state | cap_negotiating: false})}

      _ ->
        {:continue, state}
    end
  end

  defp handle_pass(msg, state) do
    case Protocol.Message.args(msg) do
      [pw | _] ->
        cond do
          state.registered ->
            reply(state, Numerics.already_registered(state.server, nick_or_star(state)))
            {:continue, state}

          not state.password_required ->
            # PASS sent but no password configured — accept and ignore.
            {:continue, %{state | password_ok: true}}

          pw == state.password ->
            {:continue, %{state | password_ok: true}}

          true ->
            reply(state, Numerics.passwd_mismatch(state.server))
            {:close, state}
        end

      [] ->
        reply(state, Numerics.need_more_params(state.server, nick_or_star(state), "PASS"))
        {:continue, state}
    end
  end

  defp handle_nick(msg, state) do
    case Protocol.Message.args(msg) do
      [] -> nick_missing(state)
      [requested | _] -> do_handle_nick(requested, state)
    end
  end

  defp nick_missing(state) do
    reply(state, Numerics.no_nickname_given(state.server, nick_or_star(state)))
    {:continue, state}
  end

  defp do_handle_nick(requested, state) do
    cond do
      not NickMap.valid_nick?(requested) ->
        reply(state, Numerics.erroneus_nickname(state.server, nick_or_star(state), requested))
        {:continue, state}

      state.nick == requested ->
        {:continue, state}

      true ->
        case claim_nick(state, requested) do
          :ok ->
            old = state.nick
            state = %{state | nick: requested}

            if old && state.registered do
              # NICK change after registration — echoed only to the
              # changing connection. Cross-peer broadcast (so other
              # humans in the same channel see the rename) requires a
              # per-conn-room reverse index that doesn't exist yet.
              line =
                Protocol.encode(
                  prefix: prefix_for(old, state.user, state.server),
                  command: "NICK",
                  params: [requested]
                )

              send_line(state.__socket__, line)
            end

            {:continue, maybe_complete_registration(state)}

          {:error, :nickname_in_use} ->
            reply(state, Numerics.nickname_in_use(state.server, nick_or_star(state), requested))
            {:continue, state}
        end
    end
  end

  defp handle_user(_msg, %{registered: true} = state) do
    reply(state, Numerics.already_registered(state.server, state.nick))
    {:continue, state}
  end

  defp handle_user(msg, state) do
    case Protocol.Message.args(msg) do
      [user, _mode, _unused, realname] ->
        {:continue, maybe_complete_registration(%{state | user: user, realname: realname})}

      [user, _mode, _unused] ->
        {:continue, maybe_complete_registration(%{state | user: user, realname: user})}

      _ ->
        reply(state, Numerics.need_more_params(state.server, nick_or_star(state), "USER"))
        {:continue, state}
    end
  end

  defp claim_nick(%{nick: nil}, requested), do: Registry.register(requested)
  defp claim_nick(%{nick: old}, requested), do: Registry.rename(old, requested)

  defp maybe_complete_registration(%{registered: true} = state), do: state

  defp maybe_complete_registration(state) do
    cond do
      state.cap_negotiating -> state
      not state.password_ok -> state
      is_nil(state.nick) -> state
      is_nil(state.user) -> state
      true -> complete_registration(state)
    end
  end

  defp complete_registration(state) do
    n = state.nick
    s = state.server

    reply(state, Numerics.welcome(s, n))
    reply(state, Numerics.your_host(s, n, state.version))
    reply(state, Numerics.created(s, n, state.created_at))
    reply(state, Numerics.my_info(s, n, state.version))

    reply(
      state,
      Numerics.isupport(s, n, [
        "NETWORK=Egghead",
        "CHANTYPES=#",
        "PREFIX=(v)+",
        "NICKLEN=30",
        "CASEMAPPING=ascii",
        "CHATHISTORY=#{@chathistory_max}"
      ])
    )

    schedule_keepalive()

    Logger.info(
      "IRC: registered nick=#{n} caps=#{inspect(MapSet.to_list(state.caps))} " <>
        "(history-replay-on-join: #{if MapSet.member?(state.caps, "server-time"), do: "yes", else: "no — needs server-time cap"})"
    )

    %{state | registered: true}
  end

  # --- Liveness ---

  defp handle_ping(msg, state) do
    # Inbound `PING [:]token` from the client — echo `:server PONG :token`
    # back. Some IRC clients (ERC included) compare the trailing token
    # to what they sent; packing the server name in middle params as
    # well confuses the match. Keep the response shape minimal.
    Logger.debug(fn -> "IRC: <- PING (#{state.nick || "*"})" end)

    pong =
      case Protocol.Message.args(msg) do
        [token | _] ->
          %Protocol.Message{prefix: state.server, command: "PONG", trailing: token}

        [] ->
          %Protocol.Message{prefix: state.server, command: "PONG", trailing: state.server}
      end

    reply(state, pong)
    {:continue, state}
  end

  # --- Channel ops ---

  defp handle_join(msg, state) do
    case Protocol.Message.args(msg) do
      [channels | _] ->
        state =
          channels
          |> String.split(",", trim: true)
          |> Enum.reduce(state, fn ch, st -> do_join(ch, st) end)

        {:continue, state}

      [] ->
        reply(state, Numerics.need_more_params(state.server, state.nick, "JOIN"))
        {:continue, state}
    end
  end

  defp do_join(channel, state) do
    # `#default` is a per-connection alias for the configured default
    # room (or the auto-created dated fallback). Resolve to canonical
    # room id internally, but remember the alias name so every wire
    # echo for this connection (JOIN, NAMES, PRIVMSG, actions) uses
    # the channel name the user actually typed. Strict clients (ERC)
    # only open a buffer when the JOIN echo matches the request.
    {canonical_channel, alias_name} = resolve_alias(channel)

    case NickMap.channel_to_room(canonical_channel) do
      nil ->
        reply(
          state,
          %Protocol.Message{
            prefix: state.server,
            command: "403",
            params: [state.nick, channel],
            trailing: "No such channel"
          }
        )

        state

      room_id ->
        ensure_room(room_id)

        if MapSet.member?(state.channels, room_id) do
          state
        else
          state =
            state
            |> subscribe_room(room_id)
            |> put_alias(room_id, alias_name)

          display = display_channel(state, room_id)

          # Echo JOIN with the user's typed channel name — that's how
          # the client knows the JOIN succeeded for *that* request.
          send_line(
            state.__socket__,
            Protocol.encode(
              prefix: prefix_for(state.nick, state.user, state.server),
              command: "JOIN",
              params: [display]
            )
          )

          # Topic before NAMES — common server ordering and keeps `366`
          # (end-of-names) as the final marker of the JOIN burst.
          send_topic(state, room_id)
          send_names(display, room_id, state)
          send_history(state.__socket__, state, room_id)
          state
        end
    end
  end

  # Replay the last `@history_replay_count` transcript messages into the
  # client's scrollback. Gated on `server-time` — without it, the
  # replayed lines would render at the current timestamp, which is
  # actively misleading for old content (looks like a duplicate flood
  # of "live" messages from minutes-or-days ago). Clients without
  # server-time can still pull history on demand via `CHATHISTORY` if
  # they support that cap; clients without either get nothing on JOIN.
  defp send_history(socket, state, room_id) do
    if MapSet.member?(state.caps, "server-time") and Room.exists?(room_id) do
      transcript =
        case Room.get_transcript(room_id) do
          msgs when is_list(msgs) -> msgs
          _ -> []
        end

      transcript
      |> Enum.take(-@history_replay_count)
      |> Enum.each(&send_history_message(socket, state, room_id, &1))
    end
  end

  # Single transcript line as a backdated PRIVMSG. `/pass` markers
  # (sender is :agent, content is "/pass") are skipped — they're a
  # transcript convention, not text the user wants to see in scrollback.
  defp send_history_message(_socket, _state, _room_id, %{
         sender: %{type: :agent},
         content: "/pass"
       }),
       do: :ok

  defp send_history_message(socket, state, room_id, msg) do
    nick =
      case msg.sender.type do
        :user -> msg.sender.name
        :agent -> NickMap.id_to_nick(msg.sender.id)
      end

    channel = display_channel(state, room_id)
    tags = time_tag(state, msg.timestamp)

    msg.content
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(fn line ->
      send_line(
        socket,
        Protocol.encode(
          tags: tags,
          prefix: nick,
          command: "PRIVMSG",
          params: [channel],
          trailing: line
        )
      )
    end)
  end

  # Synthesized channel topic — currently just an agent count. Lives in
  # the channel header in most clients; cheap signal for "is this room
  # active." Re-emitted whenever the roster changes (`:agent_joined` /
  # `:agent_left`).
  defp send_topic(state, room_id) do
    channel = display_channel(state, room_id)
    text = topic_text(room_id)

    reply(state, Numerics.topic_reply(state.server, state.nick, channel, text))

    reply(
      state,
      Numerics.topic_who_time(state.server, state.nick, channel, "egghead", epoch_now())
    )
  end

  # Pushed-update form (no nick prefix in 332/333; sent as a top-level
  # TOPIC line so connected clients refresh their header bar).
  defp push_topic_update(socket, state, room_id) do
    channel = display_channel(state, room_id)
    text = topic_text(room_id)

    send_line(
      socket,
      Protocol.encode(prefix: state.server, command: "TOPIC", params: [channel], trailing: text)
    )
  end

  defp topic_text(room_id) do
    n = room_member_count(room_id)
    plural = if n == 1, do: "agent", else: "agents"
    "#{n} #{plural}"
  end

  # Returns `{canonical_channel, alias_or_nil}`. `#default` becomes
  # `{"#chat-...", "#default"}`; everything else is `{channel, nil}`.
  defp resolve_alias("#default") do
    case Egghead.default_room() do
      nil -> {"#default", nil}
      room_id -> {NickMap.room_to_channel(room_id), "#default"}
    end
  end

  defp resolve_alias(other), do: {other, nil}

  defp put_alias(state, _room_id, nil), do: state

  defp put_alias(state, room_id, alias_name) do
    %{state | aliases: Map.put(state.aliases, room_id, alias_name)}
  end

  # Channel name to use when this connection emits anything for `room_id`
  # back over the wire. Falls through to the canonical name when no
  # alias is set.
  defp display_channel(state, room_id) do
    Map.get(state.aliases, room_id) || NickMap.room_to_channel(room_id)
  end

  # Reverse lookup for inbound traffic. Three layers:
  # 1. Per-connection alias (set on JOIN #default → that room id)
  # 2. Global `#default` alias (so KICK/INVITE work even without a JOIN)
  # 3. Canonical: strip `#`/`&`/etc.
  # Returns the room id, or nil if the channel name doesn't look like a
  # channel at all.
  defp target_to_room_id(state, channel) do
    cond do
      match = Enum.find(state.aliases, fn {_room_id, alias_name} -> alias_name == channel end) ->
        elem(match, 0)

      channel == "#default" ->
        Egghead.default_room() || NickMap.channel_to_room(channel)

      true ->
        NickMap.channel_to_room(channel)
    end
  end

  # Spawn a forwarder Task that subscribes to the room's PubSub topic
  # and re-sends each message tagged with the room_id. Linked to the
  # connection process so socket close kills the forwarder; unsubscribe
  # is handled implicitly when the forwarder exits.
  defp subscribe_room(state, room_id) do
    parent = self()
    pid = spawn_link(fn -> route_room(parent, room_id) end)

    %{
      state
      | channels: MapSet.put(state.channels, room_id),
        routers: Map.put(state.routers, room_id, pid)
    }
  end

  defp route_room(parent, room_id) do
    Phoenix.PubSub.subscribe(@pubsub, Room.topic(room_id))
    do_route_room(parent, room_id)
  end

  defp do_route_room(parent, room_id) do
    receive do
      msg ->
        send(parent, {:room_event, room_id, msg})
        do_route_room(parent, room_id)
    end
  end

  defp drop_room(state, room_id) do
    case Map.fetch(state.routers, room_id) do
      {:ok, pid} -> Process.exit(pid, :normal)
      :error -> :ok
    end

    %{
      state
      | channels: MapSet.delete(state.channels, room_id),
        routers: Map.delete(state.routers, room_id),
        streams: drop_room_streams(state.streams, room_id),
        aliases: Map.delete(state.aliases, room_id)
    }
  end

  defp drop_room_streams(streams, room_id) do
    streams
    |> Enum.reject(fn {{rid, _agent_id}, _} -> rid == room_id end)
    |> Map.new()
  end

  defp handle_part(msg, state) do
    case Protocol.Message.args(msg) do
      [channels | rest] ->
        reason = List.first(rest, "")

        state =
          channels
          |> String.split(",", trim: true)
          |> Enum.reduce(state, fn ch, st -> do_part(ch, reason, st) end)

        {:continue, state}

      [] ->
        reply(state, Numerics.need_more_params(state.server, state.nick, "PART"))
        {:continue, state}
    end
  end

  defp do_part(channel, _reason, state) do
    case target_to_room_id(state, channel) do
      nil ->
        state

      room_id ->
        if MapSet.member?(state.channels, room_id) do
          # Echo PART with the channel name the user typed (which may
          # be an alias) — same shape as the JOIN echo so the client's
          # buffer-close logic recognizes it.
          send_line(
            state.__socket__,
            Protocol.encode(
              prefix: prefix_for(state.nick, state.user, state.server),
              command: "PART",
              params: [channel]
            )
          )

          drop_room(state, room_id)
        else
          state
        end
    end
  end

  defp handle_privmsg(msg, state) do
    case Protocol.Message.args(msg) do
      [target, body] -> do_privmsg(target, body, state)
      _ -> privmsg_missing(state)
    end
  end

  defp privmsg_missing(state) do
    reply(state, Numerics.need_more_params(state.server, state.nick, "PRIVMSG"))
    {:continue, state}
  end

  # PRIVMSG to a nick (not a channel) is a DM. For agent nicks we send
  # an ephemeral 1:1 prompt via `Egghead.prompt/3` and return the
  # response as a PRIVMSG from the agent back to the asker. The prompt
  # is async (LLM call, multi-second) so we spawn a Task and let the
  # connection keep handling other commands.
  #
  # Human-to-human DM (target nick is another connected IRC client)
  # isn't wired — would need to forward the PRIVMSG to the target
  # connection's pid via Egghead.IRC.Registry.whereis/1 and a new
  # handle_info clause on the receiving side. For now we 401 unknown
  # nicks and NOTICE for known humans.
  defp do_dm(nick, body, state) do
    cond do
      match = Enum.find(safe_list_agents(), fn a -> NickMap.id_to_nick(a.id) == nick end) ->
        spawn_dm_prompt(match.id, nick, body, state)

      Registry.whereis(nick) != nil ->
        # Connected human — cross-connection DM routing not implemented.
        send_line(
          state.__socket__,
          Protocol.encode(
            prefix: state.server,
            command: "NOTICE",
            params: [state.nick],
            trailing: "Human-to-human DMs are not wired"
          )
        )

      true ->
        reply(state, Numerics.no_such_nick(state.server, state.nick, nick))
    end
  end

  defp spawn_dm_prompt(agent_id, nick, body, state) do
    socket = state.__socket__
    asker = state.nick

    Task.start(fn ->
      case Egghead.prompt(agent_id, body) do
        {:ok, %{text: text}} when is_binary(text) and text != "" ->
          # PRIVMSG from the agent (prefix = agent's nick) to the asker
          # — DMs in IRC are PRIVMSGs where the target is a nick rather
          # than a channel. Split on newlines so multi-paragraph
          # responses don't drop content.
          text
          |> String.split(~r/\r?\n/)
          |> Enum.reject(&(&1 == ""))
          |> Enum.each(fn line ->
            send_line(
              socket,
              Protocol.encode(
                prefix: nick,
                command: "PRIVMSG",
                params: [asker],
                trailing: line
              )
            )
          end)

        {:ok, _} ->
          send_line(
            socket,
            Protocol.encode(
              prefix: nick,
              command: "NOTICE",
              params: [asker],
              trailing: "(no response)"
            )
          )

        {:error, reason} ->
          send_line(
            socket,
            Protocol.encode(
              prefix: nick,
              command: "NOTICE",
              params: [asker],
              trailing: "DM failed: #{inspect(reason)}"
            )
          )
      end
    end)
  end

  defp do_privmsg(target, body, state) do
    case target_to_room_id(state, target) do
      nil ->
        do_dm(target, body, state)
        {:continue, state}

      room_id ->
        if MapSet.member?(state.channels, room_id) do
          Room.send_message(room_id, body)
        else
          # Off-channel send — RFC says 404 ERR_CANNOTSENDTOCHAN; for our
          # auto-join model we just silently drop, since the client likely
          # has stale state.
          :ok
        end

        {:continue, state}
    end
  end

  defp handle_names(msg, state) do
    case Protocol.Message.args(msg) do
      [channels | _] ->
        channels
        |> String.split(",", trim: true)
        |> Enum.each(fn ch ->
          case target_to_room_id(state, ch) do
            nil -> :ok
            room_id -> send_names(ch, room_id, state)
          end
        end)

        {:continue, state}

      [] ->
        {:continue, state}
    end
  end

  defp send_names(channel, room_id, state) do
    nicks = roster_nicks(room_id, state)
    reply(state, Numerics.names_reply(state.server, state.nick, channel, nicks))
    reply(state, Numerics.end_of_names(state.server, state.nick, channel))
  end

  defp roster_nicks(room_id, state) do
    agent_nicks =
      if Room.exists?(room_id) do
        case Room.get_state(room_id) do
          %{agents: agents} -> agents |> Enum.map(&("+" <> NickMap.id_to_nick(&1)))
          _ -> []
        end
      else
        []
      end

    # Only this connection's own nick on the human side — finding
    # other connected humans in the same channel needs a per-conn-room
    # reverse index in `Egghead.IRC.Registry` (only nick→pid today).
    [state.nick | agent_nicks]
  end

  # --- MODE ---
  #
  # Channel mode queries (`MODE #room`) get a flat "no modes set" reply;
  # we don't expose channel modes. User mode queries (`MODE nick`)
  # likewise return empty. Mode *changes* (e.g. `MODE #room +o foo`) are
  # ignored silently — agent mute/unmute uses the dedicated MUTE/UNMUTE
  # verbs rather than channel-mode `+v`/`-v`.

  defp handle_mode(msg, state) do
    case Protocol.Message.args(msg) do
      [target | _] ->
        cond do
          target == state.nick ->
            reply(state, Numerics.user_mode_is(state.server, state.nick))

          target_to_room_id(state, target) != nil ->
            reply(state, Numerics.channel_mode_is(state.server, state.nick, target))
            reply(state, Numerics.creation_time(state.server, state.nick, target, epoch_now()))

          true ->
            :ok
        end

        {:continue, state}

      [] ->
        reply(state, Numerics.need_more_params(state.server, state.nick, "MODE"))
        {:continue, state}
    end
  end

  # --- LIST ---
  #
  # `LIST` with no args lists every running room. `LIST #foo,#bar` filters
  # to specific channels. We answer with a tiny envelope: 321 header,
  # one 322 per channel (name, member count from agent roster, topic),
  # 323 footer. Connected humans aren't included in the count — that
  # would need a per-conn-room reverse index in `Egghead.IRC.Registry`.

  defp handle_list(msg, state) do
    # ERC (and some other clients) send `LIST :` with an empty trailing
    # param when the user types `/list` with no filter — args/1 then
    # returns `[""]`, not `[]`. Flatten + reject empties so any of
    # `LIST`, `LIST :`, `LIST ""`, `LIST #foo,#bar` collapse to either
    # an empty filter list (= match everything) or a real channel set.
    filters =
      msg
      |> Protocol.Message.args()
      |> Enum.flat_map(&String.split(&1, ",", trim: true))

    rooms = Room.list_ids()
    default = Egghead.default_room()

    matching =
      if filters == [],
        do: rooms,
        else: Enum.filter(rooms, fn r -> ("#" <> r) in filters end)

    Logger.debug(fn ->
      "IRC LIST  filters=#{inspect(filters)}  rooms=#{inspect(rooms)}  " <>
        "matching=#{inspect(matching)}  default=#{inspect(default)}"
    end)

    reply(state, Numerics.list_start(state.server, state.nick))

    Enum.each(matching, fn room_id ->
      topic =
        cond do
          room_id == default -> "Default room — also reachable as #default"
          true -> ""
        end

      reply(
        state,
        Numerics.list_entry(
          state.server,
          state.nick,
          NickMap.room_to_channel(room_id),
          room_member_count(room_id),
          topic
        )
      )
    end)

    reply(state, Numerics.list_end(state.server, state.nick))
    {:continue, state}
  end

  defp epoch_now, do: System.system_time(:second)

  # Member count for LIST. Counts agents currently joined to the room.
  # Many IRC clients (ERC, weechat) hide 0-user channels in list-mode
  # by default, treating them as inactive — reporting an honest count
  # keeps active rooms visible. Connected humans aren't counted —
  # would need a per-conn-room reverse index in `Egghead.IRC.Registry`.
  defp room_member_count(room_id) do
    if Room.exists?(room_id) do
      case Room.get_state(room_id) do
        # `agents` may arrive as a MapSet (live state) or a plain list
        # (newly-started room with default state); `Enum.count/1` covers
        # both without forcing one shape.
        %{agents: agents} -> Enum.count(agents)
        _ -> 0
      end
    else
      0
    end
  end

  # --- Egghead verbs (TUI slash-command palette over IRC) ---
  #
  # IRC commands don't carry a "current channel" on the wire — when the
  # user types `/save` in their #foo buffer, ERC sends a bare `SAVE`.
  # Each verb resolves the target room via `resolve_room_arg/2`:
  # explicit `#channel` first arg wins; otherwise default to the user's
  # only joined channel; otherwise 461 NEEDMOREPARAMS.

  defp handle_save(msg, state) do
    with_room(msg, state, fn _args, room_id ->
      case Room.save_transcript(room_id) do
        {:ok, record_id} ->
          reply_notice(state, "Saved transcript as #{record_id}")
          {:continue, state}

        {:error, reason} ->
          reply_notice(state, "Save failed: #{inspect(reason)}")
          {:continue, state}
      end
    end)
  end

  defp handle_continue_cmd(msg, state) do
    with_room(msg, state, fn _args, room_id ->
      Room.continue(room_id)
      {:continue, state}
    end)
  end

  defp handle_halt(msg, state) do
    with_room(msg, state, fn _args, room_id ->
      Room.halt(room_id)
      {:continue, state}
    end)
  end

  defp handle_mute(msg, state) do
    with_room_and_agent(msg, state, "MUTE", fn _room_arg, _agent_arg, room_id, agent_id ->
      Room.mute(room_id, agent_id)
      {:continue, state}
    end)
  end

  defp handle_unmute(msg, state) do
    with_room_and_agent(msg, state, "UNMUTE", fn _room_arg, _agent_arg, room_id, agent_id ->
      Room.unmute(room_id, agent_id)
      {:continue, state}
    end)
  end

  # HANDOFF runs an LLM summarization call (multi-second). Spawn it so
  # the connection stays responsive; report completion via NOTICE.
  defp handle_handoff(msg, state) do
    with_room_and_agent(msg, state, "HANDOFF", fn _room_arg, agent_arg, _room_id, agent_id ->
      socket = state.__socket__
      server = state.server
      nick = state.nick

      Task.start(fn ->
        case Egghead.handoff(agent_id, []) do
          {:ok, _summary} ->
            send_notice_direct(
              socket,
              server,
              nick,
              "#{agent_arg}: handoff complete (context cleared, summary saved)"
            )

          {:error, reason} ->
            send_notice_direct(
              socket,
              server,
              nick,
              "#{agent_arg}: handoff failed (#{inspect(reason)})"
            )
        end
      end)

      reply_notice(state, "Handing off #{agent_arg}…")
      {:continue, state}
    end)
  end

  # /context — Claude Code-style snapshot. Shows each agent's current
  # context-window utilization in the room as a NOTICE block. Compact:
  # one line per agent, percentage bar + raw counts.
  defp handle_context(msg, state) do
    with_room(msg, state, fn _args, room_id ->
      lines = context_report(room_id)
      Enum.each(lines, fn line -> reply_notice(state, line) end)
      {:continue, state}
    end)
  end

  defp context_report(room_id) do
    room_agent_ids =
      if Room.exists?(room_id) do
        case Room.get_state(room_id) do
          %{agents: agents} -> Enum.into(agents, [])
          _ -> []
        end
      else
        []
      end

    case room_agent_ids do
      [] ->
        ["No agents in this room."]

      ids ->
        all = safe_list_agents()
        roster = Enum.filter(all, fn a -> a.id in ids end)

        max_nick =
          roster |> Enum.map(&String.length(NickMap.id_to_nick(&1.id))) |> Enum.max(fn -> 0 end)

        ["Context windows:"] ++
          Enum.map(roster, fn agent ->
            nick = NickMap.id_to_nick(agent.id)
            ctx = agent.current_context_tokens || 0
            window = agent.context_window || 0
            pct = if window > 0, do: round(ctx / window * 100), else: 0
            bar = context_bar(pct)

            "  #{String.pad_trailing(nick, max_nick)}  #{bar}  #{String.pad_leading("#{pct}%", 4)}  " <>
              "(#{format_int(ctx)} / #{format_int(window)})"
          end)
    end
  end

  defp context_bar(pct) do
    width = 16
    filled = round(pct / 100 * width)
    String.duplicate("▓", filled) <> String.duplicate("░", width - filled)
  end

  defp format_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_int(_), do: "?"

  # --- Verb argument resolution ---

  # Pulls a channel arg or falls back to the user's only joined channel.
  # Calls `fun.(remaining_args, room_id)` on success; emits 461 if no
  # channel can be inferred.
  defp with_room(msg, state, fun) do
    args = Protocol.Message.args(msg)
    cmd = msg.command

    case resolve_room_arg(args, state) do
      {:ok, room_id, rest} ->
        fun.(rest, room_id)

      {:error, :no_channel} ->
        reply(state, Numerics.need_more_params(state.server, state.nick, cmd))
        {:continue, state}

      {:error, :ambiguous} ->
        reply_notice(
          state,
          "You're in multiple channels — specify one (#room) as the first argument."
        )

        {:continue, state}

      {:error, :unknown_channel} ->
        reply(state, Numerics.need_more_params(state.server, state.nick, cmd))
        {:continue, state}
    end
  end

  # Like `with_room/3` but also expects an agent nick in the args.
  # Resolves nick → agent_id by looking up the basename in the room's
  # roster (since IRC nicks drop the `agents/` namespace).
  defp with_room_and_agent(msg, state, cmd, fun) do
    with_room(msg, state, fn rest, room_id ->
      case rest do
        [agent_nick | _] ->
          case resolve_agent_in_room(agent_nick, room_id) do
            {:ok, agent_id} ->
              fun.(nil, agent_nick, room_id, agent_id)

            :not_found ->
              reply(
                state,
                %Protocol.Message{
                  prefix: state.server,
                  command: "401",
                  params: [state.nick, agent_nick],
                  trailing: "No such nick in this room"
                }
              )

              {:continue, state}
          end

        [] ->
          reply(state, Numerics.need_more_params(state.server, state.nick, cmd))
          {:continue, state}
      end
    end)
  end

  defp resolve_room_arg(args, state) do
    case args do
      ["#" <> _ = channel | rest] ->
        case target_to_room_id(state, channel) do
          nil -> {:error, :unknown_channel}
          room_id -> {:ok, room_id, rest}
        end

      _ ->
        case MapSet.to_list(state.channels) do
          [] -> {:error, :no_channel}
          [room_id] -> {:ok, room_id, args}
          _ -> {:error, :ambiguous}
        end
    end
  end

  defp resolve_agent_in_room(nick, room_id) do
    if Room.exists?(room_id) do
      case Room.get_state(room_id) do
        %{agents: agents} ->
          case Enum.find(agents, fn id -> NickMap.id_to_nick(id) == nick end) do
            nil -> :not_found
            id -> {:ok, id}
          end

        _ ->
          :not_found
      end
    else
      :not_found
    end
  end

  defp reply_notice(state, text) do
    send_notice_direct(state.__socket__, state.server, state.nick, text)
  end

  defp send_notice_direct(socket, server, nick, text) do
    send_line(
      socket,
      Protocol.encode(prefix: server, command: "NOTICE", params: [nick], trailing: text)
    )
  end

  # --- KICK / INVITE ---
  #
  # KICK and INVITE map to Room.leave/2 and Room.join/2 respectively.
  # We deliberately don't model channel ops (no +o flag, no 482
  # ERR_CHANOPRIVSNEEDED gate) — Egghead rooms are flat and any
  # participant can shape the roster, parallel to TUI semantics.

  defp handle_kick(msg, state) do
    case Protocol.Message.args(msg) do
      [channel, nick | _] ->
        case target_to_room_id(state, channel) do
          nil ->
            reply(state, Numerics.no_such_nick(state.server, state.nick, channel))
            {:continue, state}

          room_id ->
            unless MapSet.member?(state.channels, room_id) do
              reply(state, Numerics.not_on_channel(state.server, state.nick, channel))
            end

            case resolve_agent_in_room(nick, room_id) do
              {:ok, agent_id} ->
                Room.leave(room_id, agent_id)

              :not_found ->
                reply(state, Numerics.no_such_nick(state.server, state.nick, nick))
            end

            {:continue, state}
        end

      _ ->
        reply(state, Numerics.need_more_params(state.server, state.nick, "KICK"))
        {:continue, state}
    end
  end

  defp handle_invite(msg, state) do
    # IRC convention is `INVITE <nick> <channel>` — note the order
    # differs from KICK. Some clients accept the reverse; tolerate both.
    case Protocol.Message.args(msg) do
      [a, b | _] ->
        {nick, channel} =
          cond do
            String.starts_with?(a, "#") -> {b, a}
            String.starts_with?(b, "#") -> {a, b}
            true -> {a, b}
          end

        do_invite(nick, channel, state)

      _ ->
        reply(state, Numerics.need_more_params(state.server, state.nick, "INVITE"))
        {:continue, state}
    end
  end

  defp do_invite(nick, channel, state) do
    case target_to_room_id(state, channel) do
      nil ->
        reply(state, Numerics.no_such_nick(state.server, state.nick, channel))
        {:continue, state}

      room_id ->
        case resolve_agent_anywhere(nick) do
          {:ok, agent_id} ->
            unless Room.exists?(room_id) do
              # INVITE auto-creates like JOIN — otherwise typing
              # `/invite scout #brand-new-room` would silently no-op
              # or crash on the missing GenServer.
              ensure_room(room_id)
            end

            already? =
              Room.exists?(room_id) and
                case Room.get_state(room_id) do
                  %{agents: agents} -> agent_id in agents
                  _ -> false
                end

            cond do
              already? ->
                reply(state, Numerics.user_on_channel(state.server, state.nick, nick, channel))

              not Room.exists?(room_id) ->
                reply(state, Numerics.no_such_nick(state.server, state.nick, channel))

              true ->
                Room.join(room_id, agent_id)
                reply(state, Numerics.inviting(state.server, state.nick, nick, channel))
            end

          :not_found ->
            # Only agent invites are wired. Inviting another connected
            # human would forward an INVITE message to their connection
            # process via Egghead.IRC.Registry.whereis/1.
            reply(state, Numerics.no_such_nick(state.server, state.nick, nick))
        end

        {:continue, state}
    end
  end

  # Find an agent by IRC nick across the whole agent registry (not
  # scoped to a room). Used by INVITE — KICK / MUTE / UNMUTE use
  # `resolve_agent_in_room/2` instead since they only operate on the
  # current roster.
  defp resolve_agent_anywhere(nick) do
    case Enum.find(safe_list_agents(), fn a -> NickMap.id_to_nick(a.id) == nick end) do
      nil -> :not_found
      agent -> {:ok, agent.id}
    end
  end

  # `Egghead.Agent.list_agents/0` requires the record store to be up.
  # In test (and degraded headless modes) it isn't, and would crash the
  # connection. Wrap so resolution / WHOIS gracefully report "no such
  # nick" instead of dropping the socket.
  defp safe_list_agents do
    try do
      Egghead.Agent.list_agents()
    catch
      _, _ -> []
    end
  end

  # --- WHOIS ---
  #
  # WHOIS for an agent packs model + context % into 311's realname,
  # tags + capabilities into 312's server-info, walks `Room.list_ids/0`
  # for 319 channel membership, and emits 335 RPL_WHOISBOT to mark the
  # nick as a bot in modern clients. WHOIS for a connected human
  # returns 311 + 312 only — joined-channels for humans needs a
  # per-conn-room reverse index in `Egghead.IRC.Registry`.

  defp handle_whois(msg, state) do
    case Protocol.Message.args(msg) do
      [target | _] ->
        agent_match =
          Enum.find(safe_list_agents(), fn a -> NickMap.id_to_nick(a.id) == target end)

        cond do
          agent_match -> whois_agent(target, agent_match, state)
          Registry.whereis(target) != nil -> whois_human(target, state)
          true -> reply(state, Numerics.no_such_nick(state.server, state.nick, target))
        end

        reply(state, Numerics.end_of_whois(state.server, state.nick, target))
        {:continue, state}

      [] ->
        reply(state, Numerics.need_more_params(state.server, state.nick, "WHOIS"))
        {:continue, state}
    end
  end

  defp whois_agent(nick, agent, state) do
    # Pack metadata into the realname (311) and server-info (312)
    # fields, which clients render verbatim. Avoid 320 RPL_WHOISSPECIAL
    # — ERC and several other clients hardcode it as "is identified to
    # services" regardless of trailing text. 335 RPL_WHOISBOT marks
    # agents distinctly in modern clients.
    #
    # NOTE: deliberately not surfacing `agent.disposition` here. That
    # field is `record.body || ""` (see `lib/egghead/record/agent.ex`)
    # — i.e. the whole system prompt, multi-paragraph. Client renderers
    # wrap it across many lines. Tags and capabilities are short labels
    # that fit on one line each.
    ctx = agent.current_context_tokens || 0
    window = agent.context_window || 0
    pct = if window > 0, do: round(ctx / window * 100), else: 0

    realname =
      [agent.name, agent.model || "no model", "context #{pct}%"]
      |> Enum.join(" · ")

    info =
      ["Egghead agent · #{agent.id}"]
      |> maybe_append(format_tags(agent.tags), fn t -> "tags: #{t}" end)
      |> maybe_append(format_caps(agent.capabilities), fn c -> "caps: #{c}" end)
      |> Enum.join(" · ")

    reply(
      state,
      Numerics.whois_user(state.server, state.nick, nick, "agent", state.server, realname)
    )

    reply(state, Numerics.whois_server(state.server, state.nick, nick, state.server, info))

    channels = agent_channels(agent.id)

    if channels != [] do
      reply(state, Numerics.whois_channels(state.server, state.nick, nick, channels))
    end

    reply(state, Numerics.whois_bot(state.server, state.nick, nick))
  end

  defp maybe_append(list, nil, _fmt), do: list
  defp maybe_append(list, "", _fmt), do: list
  defp maybe_append(list, [], _fmt), do: list
  defp maybe_append(list, value, fmt), do: list ++ [fmt.(value)]

  defp format_caps(nil), do: nil
  defp format_caps([]), do: nil

  defp format_caps(caps) do
    caps
    |> Enum.map(fn
      %{resource: r, verb: v} -> "#{r}.#{v}"
      other -> inspect(other)
    end)
    |> Enum.join(", ")
  end

  defp format_tags(nil), do: nil
  defp format_tags([]), do: nil
  defp format_tags(tags) when is_list(tags), do: Enum.join(tags, ", ")
  defp format_tags(_), do: nil

  defp whois_human(nick, state) do
    reply(
      state,
      Numerics.whois_user(state.server, state.nick, nick, "user", state.server, nick)
    )

    reply(
      state,
      Numerics.whois_server(state.server, state.nick, nick, state.server, "Egghead human user")
    )
  end

  defp agent_channels(agent_id) do
    Room.list_ids()
    |> Enum.filter(fn room_id ->
      Room.exists?(room_id) and
        case Room.get_state(room_id) do
          %{agents: agents} -> agent_id in agents
          _ -> false
        end
    end)
    |> Enum.map(&NickMap.room_to_channel/1)
  end

  # --- MOTD / VERSION / TIME ---

  @motd [
    "Welcome to Egghead — record-store-first multi-agent system.",
    "",
    "Try /list to see active rooms.",
    "Try /context for a snapshot of agent context windows.",
    "Mention @everyone to address all agents at once,",
    "or @<agent> for a single one.",
    "",
    "Source: https://github.com/mwunsch/egghead"
  ]

  defp handle_motd(_msg, state) do
    reply(state, Numerics.motd_start(state.server, state.nick))
    Enum.each(@motd, fn line -> reply(state, Numerics.motd(state.server, state.nick, line)) end)
    reply(state, Numerics.end_of_motd(state.server, state.nick))
    {:continue, state}
  end

  defp handle_version(_msg, state) do
    reply(
      state,
      Numerics.version_reply(
        state.server,
        state.nick,
        state.version,
        "Egghead IRC — record store + agents on tap"
      )
    )

    {:continue, state}
  end

  defp handle_time(_msg, state) do
    reply(
      state,
      Numerics.time_reply(state.server, state.nick, DateTime.utc_now() |> DateTime.to_iso8601())
    )

    {:continue, state}
  end

  # --- CHATHISTORY ---
  #
  # IRCv3 chat history extension (https://ircv3.net/specs/extensions/chathistory).
  # Five subcommands:
  #
  #   CHATHISTORY LATEST  <target> *                       <limit>
  #   CHATHISTORY BEFORE  <target> timestamp=<iso>         <limit>
  #   CHATHISTORY AFTER   <target> timestamp=<iso>         <limit>
  #   CHATHISTORY AROUND  <target> timestamp=<iso>         <limit>
  #   CHATHISTORY BETWEEN <target> timestamp=<iso> timestamp=<iso> <limit>
  #
  # Response: a `BATCH +<id> chathistory <target>` envelope wrapping
  # one PRIVMSG per matching transcript message (each tagged with
  # `@time=<iso>` and `@batch=<id>`), terminated by `BATCH -<id>`.
  # Any failure surfaces as a `FAIL CHATHISTORY <code> :<desc>` line.

  defp handle_chathistory(msg, state) do
    case Protocol.Message.args(msg) do
      [subcommand | rest] ->
        do_chathistory(String.upcase(subcommand), rest, state)

      [] ->
        reply_chat_fail(state, "NEED_MORE_PARAMS", [], "CHATHISTORY needs a subcommand")
    end

    {:continue, state}
  end

  defp do_chathistory("LATEST", [target, _selector, limit_str | _], state) do
    # Latest N messages overall, no filter.
    chathistory_window(state, target, limit_str, fn _msg -> true end, :latest)
  end

  defp do_chathistory("BEFORE", [target, ts_arg, limit_str | _], state) do
    case parse_chathistory_timestamp(ts_arg) do
      {:ok, ts} ->
        # Strictly earlier than `ts`; keep the latest matching N
        # (closest to `ts` going backward in time).
        chathistory_window(
          state,
          target,
          limit_str,
          fn msg -> DateTime.compare(msg.timestamp, ts) == :lt end,
          :latest
        )

      :error ->
        reply_chat_fail(state, "INVALID_PARAMS", [target], "BEFORE needs timestamp=<iso8601>")
    end
  end

  defp do_chathistory("AFTER", [target, ts_arg, limit_str | _], state) do
    case parse_chathistory_timestamp(ts_arg) do
      {:ok, ts} ->
        # Strictly after `ts`; keep the earliest matching N (closest
        # to `ts` going forward in time).
        chathistory_window(
          state,
          target,
          limit_str,
          fn msg -> DateTime.compare(msg.timestamp, ts) == :gt end,
          :earliest
        )

      :error ->
        reply_chat_fail(state, "INVALID_PARAMS", [target], "AFTER needs timestamp=<iso8601>")
    end
  end

  defp do_chathistory("AROUND", [target, ts_arg, limit_str | _], state) do
    case parse_chathistory_timestamp(ts_arg) do
      {:ok, ts} ->
        # Half before, half after — pivot on the timestamp.
        limit = clamp_chathistory_limit(limit_str)
        half = max(div(limit, 2), 1)

        emit_chathistory(state, target, fn msgs ->
          {before, after_} =
            Enum.split_with(msgs, fn m -> DateTime.compare(m.timestamp, ts) != :gt end)

          (Enum.take(before, -half) ++ Enum.take(after_, half))
          |> Enum.take(limit)
        end)

      :error ->
        reply_chat_fail(state, "INVALID_PARAMS", [target], "AROUND needs timestamp=<iso8601>")
    end
  end

  defp do_chathistory("BETWEEN", [target, ts1_arg, ts2_arg, limit_str | _], state) do
    with {:ok, ts1} <- parse_chathistory_timestamp(ts1_arg),
         {:ok, ts2} <- parse_chathistory_timestamp(ts2_arg) do
      {lo, hi} = if DateTime.compare(ts1, ts2) == :lt, do: {ts1, ts2}, else: {ts2, ts1}

      chathistory_window(
        state,
        target,
        limit_str,
        fn msg ->
          DateTime.compare(msg.timestamp, lo) != :lt and
            DateTime.compare(msg.timestamp, hi) != :gt
        end,
        :earliest
      )
    else
      _ ->
        reply_chat_fail(
          state,
          "INVALID_PARAMS",
          [target],
          "BETWEEN needs two timestamp=<iso8601> args"
        )
    end
  end

  defp do_chathistory(sub, args, state) do
    target = List.first(args, "*")

    reply_chat_fail(
      state,
      "UNKNOWN_COMMAND",
      [target],
      "CHATHISTORY #{sub} is not supported"
    )
  end

  # Filter the transcript and take a window. `which` is `:latest`
  # (closest to "now" — Enum.take(-N)) or `:earliest` (closest to the
  # filter's pivot — Enum.take(N)).
  defp chathistory_window(state, target, limit_str, filter, which) do
    limit = clamp_chathistory_limit(limit_str)

    emit_chathistory(state, target, fn msgs ->
      filtered = Enum.filter(msgs, filter)

      case which do
        :latest -> Enum.take(filtered, -limit)
        :earliest -> Enum.take(filtered, limit)
      end
    end)
  end

  # Resolve target → room, fetch transcript, run selector, emit a
  # BATCH-wrapped sequence of PRIVMSGs.
  defp emit_chathistory(state, target, selector) do
    case target_to_room_id(state, target) do
      nil ->
        reply_chat_fail(state, "INVALID_TARGET", [target], "Unknown channel")

      room_id ->
        if Room.exists?(room_id) do
          transcript =
            case Room.get_transcript(room_id) do
              msgs when is_list(msgs) -> msgs
              _ -> []
            end

          # /pass markers are a transcript convention, not chat content.
          chat_only =
            Enum.reject(transcript, fn m ->
              m.sender.type == :agent and m.content == "/pass"
            end)

          selected = selector.(chat_only)
          send_chathistory_batch(state, target, room_id, selected)
        else
          reply_chat_fail(state, "INVALID_TARGET", [target], "Channel does not exist")
        end
    end
  end

  defp send_chathistory_batch(state, target, room_id, msgs) do
    socket = state.__socket__
    batch_id = chathistory_batch_id()

    # Open batch
    send_line(
      socket,
      Protocol.encode(
        prefix: state.server,
        command: "BATCH",
        params: ["+" <> batch_id, "chathistory", target]
      )
    )

    Enum.each(msgs, fn msg -> send_chathistory_line(socket, state, room_id, batch_id, msg) end)

    # Close batch
    send_line(
      socket,
      Protocol.encode(prefix: state.server, command: "BATCH", params: ["-" <> batch_id])
    )
  end

  defp send_chathistory_line(socket, state, room_id, batch_id, msg) do
    nick =
      case msg.sender.type do
        :user -> msg.sender.name
        :agent -> NickMap.id_to_nick(msg.sender.id)
      end

    channel = display_channel(state, room_id)

    tags =
      time_tag(state, msg.timestamp)
      |> Map.put("batch", batch_id)

    msg.content
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(fn line ->
      send_line(
        socket,
        Protocol.encode(
          tags: tags,
          prefix: nick,
          command: "PRIVMSG",
          params: [channel],
          trailing: line
        )
      )
    end)
  end

  defp parse_chathistory_timestamp("timestamp=" <> iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_chathistory_timestamp(_), do: :error

  defp clamp_chathistory_limit(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> min(n, @chathistory_max)
      _ -> @chathistory_max
    end
  end

  defp clamp_chathistory_limit(_), do: @chathistory_max

  defp chathistory_batch_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end

  defp reply_chat_fail(state, code, context, description) do
    reply(state, Numerics.fail(state.server, "CHATHISTORY", code, context, description))
  end

  # --- QUIT ---

  defp handle_quit(_msg, state) do
    cleanup(state)
    {:close, state}
  end

  # --- Unknown ---

  defp handle_unknown(%{command: cmd}, state) do
    reply(state, Numerics.unknown_command(state.server, nick_or_star(state), cmd))
    {:continue, state}
  end

  # --- Helpers ---

  defp ensure_room(room_id) do
    cond do
      Room.exists?(room_id) ->
        :ok

      true ->
        # `Egghead.create_room/1` is the canonical path — it auto-joins
        # the registered agents to the new room. But it depends on the
        # record store being up; in tests (and degraded headless mode)
        # we may not have it. Fall back to a bare `Room.start_link/1`
        # so an IRC client can still create and use a room.
        try do
          Egghead.create_room(id: room_id)
        catch
          _, _ -> Room.start_link(id: room_id)
        else
          {:ok, _} -> :ok
          {:error, _} -> Room.start_link(id: room_id)
          _ -> Room.start_link(id: room_id)
        end
    end
  end

  defp cleanup(state) do
    # Routers are linked to us, so they'd die with the socket regardless;
    # exit them explicitly here for a clean PART scenario where the
    # socket is still alive but the connection is winding down.
    state
    |> Map.get(:routers, %{})
    |> Map.values()
    |> Enum.each(fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    if state.nick, do: Registry.unregister(state.nick)
    :ok
  end

  defp send_privmsg(socket, state, from_nick, room_id, content) do
    channel = display_channel(state, room_id)
    tags = time_tag(state)

    # IRC PRIVMSG is one line per message; the streaming buffer splits
    # on `\n\n` upstream, but multi-line user messages still need a
    # split here so paragraphs don't drop content.
    content
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(fn line ->
      send_line(
        socket,
        Protocol.encode(
          tags: tags,
          prefix: from_nick,
          command: "PRIVMSG",
          params: [channel],
          trailing: line
        )
      )
    end)
  end

  defp reply(state, msg), do: send_line(state.__socket__, Protocol.encode(msg))

  defp send_line(socket, iodata) do
    case ThousandIsland.Socket.send(socket, iodata) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("IRC send failed: #{inspect(reason)}")
    end
  end

  defp prefix_for(nick, user, host) do
    "#{nick}!#{user || nick}@#{host}"
  end

  defp nick_or_star(%{nick: nil}), do: "*"
  defp nick_or_star(%{nick: n}), do: n

  defp own_user_message?(msg, state) do
    msg.sender.type == :user and is_binary(state.nick) and msg.sender.name == state.nick
  end
end
