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
      cap_negotiating: false
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

  def handle_info({:user_message, msg}, {socket, state}) do
    # Don't echo our own message back at us — IRC clients render what
    # they sent locally, so a server-side echo would double up.
    #
    # M1 caveat: every IRC connection currently sends as the system
    # `Egghead.User.current()` (id == $USER), not as the IRC nick. So
    # the only honest "is this mine" signal we have is comparing the
    # display name to our nick — fine for a single human, will need to
    # become a real per-conn identity check in M4.
    if MapSet.member?(state.channels, msg.room_id) and not own_user_message?(msg, state) do
      send_privmsg(socket, state, msg.sender.name, msg.room_id, msg.content)
    end

    {:noreply, {socket, state}}
  end

  def handle_info({:agent_message, msg}, {socket, state}) do
    if MapSet.member?(state.channels, msg.room_id) do
      send_privmsg(socket, state, NickMap.id_to_nick(msg.sender.id), msg.room_id, msg.content)
    end

    {:noreply, {socket, state}}
  end

  def handle_info({:room_stopped, room_id}, {socket, state}) do
    if MapSet.member?(state.channels, room_id) do
      send_line(
        socket,
        Protocol.encode(
          prefix: state.server,
          command: "NOTICE",
          params: [NickMap.room_to_channel(room_id)],
          trailing: "Room stopped"
        )
      )

      Phoenix.PubSub.unsubscribe(@pubsub, Room.topic(room_id))
      {:noreply, {socket, %{state | channels: MapSet.delete(state.channels, room_id)}}}
    else
      {:noreply, {socket, state}}
    end
  end

  def handle_info(_other, {socket, state}) do
    {:noreply, {socket, state}}
  end

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
    case NickMap.channel_to_room(channel) do
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
          Phoenix.PubSub.subscribe(@pubsub, Room.topic(room_id))

          # Echo JOIN back to client so its UI updates.
          send_line(
            state.__socket__,
            Protocol.encode(
              prefix: prefix_for(state.nick, state.user, state.server),
              command: "JOIN",
              params: [channel]
            )
          )

          state = %{state | channels: MapSet.put(state.channels, room_id)}
          send_names(channel, room_id, state)
          state
        end
    end
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
    case NickMap.channel_to_room(channel) do
      nil ->
        state

      room_id ->
        if MapSet.member?(state.channels, room_id) do
          Phoenix.PubSub.unsubscribe(@pubsub, Room.topic(room_id))

          send_line(
            state.__socket__,
            Protocol.encode(
              prefix: prefix_for(state.nick, state.user, state.server),
              command: "PART",
              params: [channel]
            )
          )

          %{state | channels: MapSet.delete(state.channels, room_id)}
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
    case NickMap.channel_to_room(target) do
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
          case NickMap.channel_to_room(ch) do
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

          NickMap.channel_to_room(target) != nil ->
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
    requested =
      case Protocol.Message.args(msg) do
        [list | _] -> String.split(list, ",", trim: true)
        [] -> :all
      end

    rooms = Room.list_ids()

    matching =
      case requested do
        :all -> rooms
        names -> Enum.filter(rooms, fn r -> ("#" <> r) in names end)
      end

    reply(state, Numerics.list_start(state.server, state.nick))

    Enum.each(matching, fn room_id ->
      reply(
        state,
        Numerics.list_entry(state.server, state.nick, NickMap.room_to_channel(room_id), 0, "")
      )
    end)

    reply(state, Numerics.list_end(state.server, state.nick))
    {:continue, state}
  end

  defp epoch_now, do: System.system_time(:second)

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
    Enum.each(state.channels, fn room_id ->
      Phoenix.PubSub.unsubscribe(@pubsub, Room.topic(room_id))
    end)

    if state.nick, do: Registry.unregister(state.nick)
    :ok
  end

  defp send_privmsg(socket, _state, from_nick, room_id, content) do
    channel = NickMap.room_to_channel(room_id)

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
