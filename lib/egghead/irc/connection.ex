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

  # --- ThousandIsland.Handler callbacks ---

  @impl ThousandIsland.Handler
  def handle_connection(_socket, _state) do
    cfg = Server.config()

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
      aliases: %{}
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

  def handle_info(_other, {socket, state}) do
    {:noreply, {socket, state}}
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
  # tool_denied/output (M3 may surface tool denials).
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

    text
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(fn line ->
      send_line(
        socket,
        Protocol.encode(
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

  # --- Command dispatch ---

  # We tuck the live socket into the state map for the duration of a
  # dispatch call so the per-command handlers don't all need an extra
  # arg. Stripped before returning.
  defp drop_socket(state), do: Map.delete(state, :__socket__)

  defp dispatch(%Protocol.Message{command: cmd} = msg, state) do
    case cmd do
      "CAP" -> handle_cap(msg, state)
      "PASS" -> handle_pass(msg, state)
      "NICK" -> handle_nick(msg, state)
      "USER" -> handle_user(msg, state)
      "PING" -> handle_ping(msg, state)
      "PONG" -> {:continue, state}
      "QUIT" -> handle_quit(msg, state)
      "JOIN" -> require_registered(state, fn -> handle_join(msg, state) end)
      "PART" -> require_registered(state, fn -> handle_part(msg, state) end)
      "PRIVMSG" -> require_registered(state, fn -> handle_privmsg(msg, state) end)
      "NAMES" -> require_registered(state, fn -> handle_names(msg, state) end)
      "MODE" -> require_registered(state, fn -> handle_mode(msg, state) end)
      "LIST" -> require_registered(state, fn -> handle_list(msg, state) end)
      # Egghead verbs — TUI slash-command palette over the IRC wire.
      # ERC's `/handoff scout` sends `HANDOFF scout`; users get the
      # exact muscle memory they have in the TUI.
      "HANDOFF" -> require_registered(state, fn -> handle_handoff(msg, state) end)
      "SAVE" -> require_registered(state, fn -> handle_save(msg, state) end)
      "CONTINUE" -> require_registered(state, fn -> handle_continue_cmd(msg, state) end)
      "HALT" -> require_registered(state, fn -> handle_halt(msg, state) end)
      "MUTE" -> require_registered(state, fn -> handle_mute(msg, state) end)
      "UNMUTE" -> require_registered(state, fn -> handle_unmute(msg, state) end)
      "CONTEXT" -> require_registered(state, fn -> handle_context(msg, state) end)
      "KICK" -> require_registered(state, fn -> handle_kick(msg, state) end)
      "INVITE" -> require_registered(state, fn -> handle_invite(msg, state) end)
      "WHOIS" -> require_registered(state, fn -> handle_whois(msg, state) end)
      "MOTD" -> require_registered(state, fn -> handle_motd(msg, state) end)
      "VERSION" -> require_registered(state, fn -> handle_version(msg, state) end)
      "TIME" -> require_registered(state, fn -> handle_time(msg, state) end)
      _ -> handle_unknown(msg, state)
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
        # No IRCv3 capabilities yet (M4 will add server-time). Reply with
        # an empty list so clients waiting on CAP LS proceed.
        reply(
          state,
          %Protocol.Message{
            prefix: state.server,
            command: "CAP",
            params: [nick_or_star(state), "LS"],
            trailing: ""
          }
        )

        {:continue, %{state | cap_negotiating: true}}

      ["REQ", caps] ->
        # NAK everything — we don't grant any capabilities today.
        reply(
          state,
          %Protocol.Message{
            prefix: state.server,
            command: "CAP",
            params: [nick_or_star(state), "NAK"],
            trailing: caps
          }
        )

        {:continue, state}

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
              # NICK change after registration — broadcast to all channels
              # we're in (for now, just echo to ourselves; M2 broadcasts
              # to peers when other connections share a channel).
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
        "CASEMAPPING=ascii"
      ])
    )

    %{state | registered: true}
  end

  # --- Liveness ---

  defp handle_ping(msg, state) do
    pong =
      case Protocol.Message.args(msg) do
        [token | _] ->
          %Protocol.Message{
            prefix: state.server,
            command: "PONG",
            params: [state.server],
            trailing: token
          }

        [] ->
          %Protocol.Message{prefix: state.server, command: "PONG", params: [state.server]}
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
          state
        end
    end
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

  defp do_privmsg(target, body, state) do
    case target_to_room_id(state, target) do
      nil ->
        # DM to a nick — M1 just NOTICE-replies that DMs aren't wired yet.
        # M3 will route to `Egghead.prompt/3`.
        send_line(
          state.__socket__,
          Protocol.encode(
            prefix: state.server,
            command: "NOTICE",
            params: [state.nick],
            trailing: "DMs to agents are not wired yet (coming in M3)"
          )
        )

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

    # Just our own nick for human side in M1 — M4 will look up other
    # connections in the same channel via the Registry.
    [state.nick | agent_nicks]
  end

  # --- MODE ---
  #
  # Channel mode queries (`MODE #room`) get a flat "no modes set" reply;
  # we don't expose channel modes today. User mode queries (`MODE nick`)
  # likewise return empty. Mode *changes* (e.g. `MODE #room +o foo`) are
  # ignored silently — when M3 wires `+v` for muting agents, this stub
  # gets replaced with a real handler.

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
  # one 322 per channel (name, member-count placeholder, empty topic),
  # 323 footer. Member counts are 0 for now because we don't track
  # connected humans across channels yet — M4 brings the full Registry
  # walk that makes this honest.

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
  # keeps active rooms visible. Connected humans aren't counted yet
  # (M4 will index IRC connections by room via the Registry).
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
            # M3 only invites agents. Inviting another connected human
            # is M4 (needs to forward an INVITE message to their
            # connection process via Egghead.IRC.Registry.whereis/1).
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
  # WHOIS for an agent populates 311 with model + disposition, 319 with
  # current room memberships, and a few 320 RPL_WHOISSPECIAL lines for
  # context-window utilization and capabilities. WHOIS for a connected
  # human shows their connection prefix and joined channels (M4 will
  # extend the latter when we track per-conn room memberships).

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

    # IRC PRIVMSG is one line per message; agents (and the future
    # streaming buffer) will need to split on `\n` upstream. For now
    # we split here so multi-line user messages don't drop content.
    content
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(fn line ->
      send_line(
        socket,
        Protocol.encode(prefix: from_nick, command: "PRIVMSG", params: [channel], trailing: line)
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
