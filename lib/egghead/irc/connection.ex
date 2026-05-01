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

  alias Egghead.IRC.{
    Protocol,
    Numerics,
    NickMap,
    Registry,
    Server,
    StreamBuffer,
    Format,
    Channels,
    ChatHistory,
    Forwarder,
    Agents,
    Whois,
    Wire,
    Verbs
  }

  alias Egghead.Chat.Room

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
  @chathistory_max ChatHistory.max()

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
      # Server-initiated keepalive state. `awaiting_pong_token` holds
      # the unique token for the most recent PING we sent (nil when no
      # PING is outstanding). `last_ping_sent_at` is the monotonic ms
      # so we can report round-trip latency on the matching PONG.
      # If the next tick fires while still awaiting, the connection
      # is dead — close it.
      awaiting_pong_token: nil,
      last_ping_sent_at: nil,
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
  def handle_info(:keepalive_tick, {socket, %{awaiting_pong_token: tok} = state})
      when is_binary(tok) do
    waited = monotonic_ms() - (state.last_ping_sent_at || 0)

    Logger.info(
      "IRC: dropping #{state.nick || "*"} — no PONG for token=#{tok} within #{waited}ms"
    )

    cleanup(state)
    {:stop, :normal, {socket, state}}
  end

  def handle_info(:keepalive_tick, {socket, state}) do
    token = fresh_ping_token()

    Logger.debug(fn -> "IRC: -> PING #{state.nick || "*"} token=#{token}" end)

    send_line(
      socket,
      Protocol.encode(prefix: state.server, command: "PING", trailing: token)
    )

    schedule_keepalive()

    {:noreply, {socket, %{state | awaiting_pong_token: token, last_ping_sent_at: monotonic_ms()}}}
  end

  def handle_info(_other, {socket, state}) do
    {:noreply, {socket, state}}
  end

  defp schedule_keepalive do
    Process.send_after(self(), :keepalive_tick, @ping_interval)
  end

  # Short, unique tokens for server-initiated PINGs so we can match
  # incoming PONGs to the correct outstanding request and report
  # round-trip latency.
  defp fresh_ping_token do
    :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  # Inbound PONG: log the round trip if we have a matching outstanding
  # token, otherwise note the unsolicited PONG (e.g. client responding
  # to its own clock or to a PING from a previous connection).
  defp handle_pong_reply(msg, state) do
    received = Protocol.Message.args(msg) |> List.first()
    nick = state.nick || "*"

    Logger.debug(fn ->
      cond do
        is_nil(state.awaiting_pong_token) ->
          "IRC: <- PONG #{nick} token=#{inspect(received)} (unsolicited)"

        received == state.awaiting_pong_token ->
          rtt = monotonic_ms() - (state.last_ping_sent_at || 0)
          "IRC: <- PONG #{nick} token=#{received} rtt=#{rtt}ms"

        true ->
          "IRC: <- PONG #{nick} token=#{inspect(received)} (expected #{state.awaiting_pong_token})"
      end
    end)
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
    {tail, streams} = StreamBuffer.take_tail(state.streams, room_id, msg.sender.id, msg.content)
    state = %{state | streams: streams}

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
    {to_emit, streams} = StreamBuffer.absorb(state.streams, room_id, agent_id, delta)
    state = %{state | streams: streams}

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
    summary = "uses #{name}#{Format.tool_input(input)}"
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

  # --- Wire helpers for actions / notices ---

  # Channel-aware wrappers around `Wire` — these resolve the per-conn
  # display alias and current server-time tag set, then delegate the
  # actual line shaping. Kept as defps so the 100+ call sites in this
  # module stay terse.

  defp send_action(socket, state, nick, room_id, text) do
    Wire.send_action(socket, nick, display_channel(state, room_id), text, time_tag(state))
    state
  end

  defp send_notice(socket, state, room_id, text) do
    Wire.send_notice(socket, state.server, display_channel(state, room_id), text, time_tag(state))
    state
  end

  defp agent_prefix(nick, state), do: Wire.agent_prefix(nick, state.server)

  defp time_tag(state, dt \\ nil), do: Wire.time_tag(state.caps, dt)

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
        handle_pong_reply(msg, state)
        {:continue, %{state | awaiting_pong_token: nil, last_ping_sent_at: nil}}

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
      # exact muscle memory they have in the TUI. Implementation lives
      # in `Egghead.IRC.Verbs`.
      verb when verb in ["HANDOFF", "SAVE", "CONTINUE", "HALT", "MUTE", "UNMUTE", "CONTEXT"] ->
        require_registered(state, fn ->
          Verbs.handle(msg, verbs_ctx(state))
          {:continue, state}
        end)

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
    token = Protocol.Message.args(msg) |> List.first()
    nick = state.nick || "*"

    Logger.debug(fn -> "IRC: <- PING #{nick} token=#{inspect(token)}" end)

    response_token = token || state.server
    Logger.debug(fn -> "IRC: -> PONG #{nick} token=#{response_token}" end)

    reply(state, %Protocol.Message{
      prefix: state.server,
      command: "PONG",
      trailing: response_token
    })

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
    {canonical_channel, alias_name} = Channels.resolve_alias(channel)

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
            |> Map.update!(:aliases, &Channels.put_alias(&1, room_id, alias_name))

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

    Wire.send_privmsg(
      socket,
      nick,
      display_channel(state, room_id),
      msg.content,
      time_tag(state, msg.timestamp)
    )
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

  defp display_channel(state, room_id), do: Channels.display_channel(state.aliases, room_id)

  defp target_to_room_id(state, channel),
    do: Channels.target_to_room_id(state.aliases, channel)

  defp subscribe_room(state, room_id) do
    pid = Forwarder.start_link(self(), room_id)

    %{
      state
      | channels: MapSet.put(state.channels, room_id),
        routers: Map.put(state.routers, room_id, pid)
    }
  end

  defp drop_room(state, room_id) do
    case Map.fetch(state.routers, room_id) do
      {:ok, pid} -> Forwarder.stop(pid)
      :error -> :ok
    end

    %{
      state
      | channels: MapSet.delete(state.channels, room_id),
        routers: Map.delete(state.routers, room_id),
        streams: StreamBuffer.drop_room(state.streams, room_id),
        aliases: Map.delete(state.aliases, room_id)
    }
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
      match = Agents.find_by_nick(nick) ->
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

  # Slash-verb context bundle. Built per-dispatch from the live state —
  # `Verbs.handle/2` reads it but doesn't keep a reference.
  defp verbs_ctx(state) do
    %{
      server: state.server,
      nick: state.nick,
      channels: state.channels,
      aliases: state.aliases,
      socket: state.__socket__,
      emit: fn iodata -> Wire.write(state.__socket__, iodata) end
    }
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

            case Agents.find_in_room(nick, room_id) do
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
    case Agents.find_by_nick(nick) do
      nil -> :not_found
      agent -> {:ok, agent.id}
    end
  end

  # --- WHOIS ---
  #
  # Subprotocol lives in `Egghead.IRC.Whois`; this clause builds the
  # context bundle and delegates.

  defp handle_whois(msg, state) do
    ctx = %{
      server: state.server,
      nick: state.nick,
      emit: fn iodata -> send_line(state.__socket__, iodata) end
    }

    Whois.handle(msg, ctx)
    {:continue, state}
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
  # IRCv3 chat history extension. The subprotocol lives in
  # `Egghead.IRC.ChatHistory`; this clause builds the small context
  # bundle (server name, alias map, emit + time_tag callbacks) and
  # delegates.

  defp handle_chathistory(msg, state) do
    ctx = %{
      server: state.server,
      nick: state.nick,
      aliases: state.aliases,
      emit: fn iodata -> send_line(state.__socket__, iodata) end,
      time_tag: &time_tag(state, &1)
    }

    ChatHistory.handle(msg, ctx)
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
    # Forwarders are linked to us, so they'd die with the socket
    # regardless; stop them explicitly here for a clean PART scenario
    # where the socket is still alive but the connection is winding down.
    state
    |> Map.get(:routers, %{})
    |> Map.values()
    |> Enum.each(&Forwarder.stop/1)

    if state.nick, do: Registry.unregister(state.nick)
    :ok
  end

  defp send_privmsg(socket, state, from_nick, room_id, content) do
    Wire.send_privmsg(
      socket,
      from_nick,
      display_channel(state, room_id),
      content,
      time_tag(state)
    )
  end

  defp reply(state, msg), do: Wire.send_message(state.__socket__, msg)

  defp send_line(socket, iodata), do: Wire.write(socket, iodata)

  defp prefix_for(nick, user, host), do: Wire.prefix(nick, user, host)

  defp nick_or_star(%{nick: nil}), do: "*"
  defp nick_or_star(%{nick: n}), do: n

  defp own_user_message?(msg, state) do
    msg.sender.type == :user and is_binary(state.nick) and msg.sender.name == state.nick
  end
end
