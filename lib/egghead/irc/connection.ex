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
  # nicklist updates live without needing a fresh /NAMES query.
  defp handle_room_event({:agent_joined, agent_id}, room_id, socket, state) do
    nick = NickMap.id_to_nick(agent_id)
    channel = display_channel(state, room_id)
    line = Protocol.encode(prefix: agent_prefix(nick, state), command: "JOIN", params: [channel])
    send_line(socket, line)
    state
  end

  defp handle_room_event({:agent_left, agent_id}, room_id, socket, state) do
    nick = NickMap.id_to_nick(agent_id)
    channel = display_channel(state, room_id)
    line = Protocol.encode(prefix: agent_prefix(nick, state), command: "PART", params: [channel])
    send_line(socket, line)
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

          send_names(display, room_id, state)
          state
        end
    end
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

  # Reverse lookup for inbound traffic. Client sends `PRIVMSG #default :hi`
  # — `#default` isn't a room id, but we have an alias entry pointing it
  # at the canonical room. Returns the room id, or nil if the channel
  # name doesn't resolve to anything we know.
  defp target_to_room_id(state, channel) do
    case Enum.find(state.aliases, fn {_room_id, alias_name} -> alias_name == channel end) do
      {room_id, _alias} -> room_id
      nil -> NickMap.channel_to_room(channel)
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
