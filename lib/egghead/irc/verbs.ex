defmodule Egghead.IRC.Verbs do
  @moduledoc """
  Egghead-specific slash-command verbs over IRC: SAVE, CONTINUE, HALT,
  MUTE, UNMUTE, HANDOFF, CONTEXT. These mirror the TUI's slash palette
  so ERC's `/handoff scout` Just Works.

  IRC commands don't carry a "current channel" on the wire — when the
  user types `/save` in their `#foo` buffer, ERC sends a bare `SAVE`.
  Each verb resolves the target room via `resolve_room_arg/2`: explicit
  `#channel` first arg wins; otherwise default to the user's only
  joined channel; otherwise 461 NEEDMOREPARAMS.

  All wire emission flows through the `emit` callback the connection
  passes in (matching `ChatHistory` / `Whois`), so this module stays
  ignorant of sockets.
  """

  alias Egghead.IRC.{Protocol, Numerics, NickMap, Channels, Format, Agents, Wire}
  alias Egghead.Chat.Room

  @type ctx :: %{
          required(:server) => String.t(),
          required(:nick) => String.t(),
          required(:channels) => MapSet.t(),
          required(:aliases) => map(),
          required(:socket) => term(),
          required(:emit) => (iodata() -> any())
        }

  @verbs ~w(SAVE CONTINUE HALT MUTE UNMUTE HANDOFF CONTEXT)

  @doc "List of verbs handled by this module. Used by `Connection.dispatch`."
  def verbs, do: @verbs

  @doc "Dispatch a parsed slash-verb message."
  def handle(%Protocol.Message{command: cmd} = msg, ctx) when cmd in @verbs do
    do_handle(cmd, msg, ctx)
  end

  defp do_handle("SAVE", msg, ctx) do
    with_room(msg, ctx, fn _args, room_id ->
      case Room.save_transcript(room_id) do
        {:ok, record_id} -> notice(ctx, "Saved transcript as #{record_id}")
        {:error, reason} -> notice(ctx, "Save failed: #{inspect(reason)}")
      end
    end)
  end

  defp do_handle("CONTINUE", msg, ctx) do
    with_room(msg, ctx, fn _args, room_id -> Room.continue(room_id) end)
  end

  defp do_handle("HALT", msg, ctx) do
    with_room(msg, ctx, fn _args, room_id -> Room.halt(room_id) end)
  end

  defp do_handle("MUTE", msg, ctx) do
    with_room_and_agent(msg, ctx, fn _agent_arg, room_id, agent_id ->
      Room.mute(room_id, agent_id)
    end)
  end

  defp do_handle("UNMUTE", msg, ctx) do
    with_room_and_agent(msg, ctx, fn _agent_arg, room_id, agent_id ->
      Room.unmute(room_id, agent_id)
    end)
  end

  # HANDOFF runs an LLM summarization call (multi-second). Spawn it so
  # the connection stays responsive; report completion via NOTICE.
  defp do_handle("HANDOFF", msg, ctx) do
    with_room_and_agent(msg, ctx, fn agent_arg, _room_id, agent_id ->
      socket = ctx.socket
      server = ctx.server
      nick = ctx.nick

      Task.start(fn ->
        case Egghead.handoff(agent_id, []) do
          {:ok, _summary} ->
            Wire.send_notice(
              socket,
              server,
              nick,
              "#{agent_arg}: handoff complete (context cleared, summary saved)"
            )

          {:error, reason} ->
            Wire.send_notice(
              socket,
              server,
              nick,
              "#{agent_arg}: handoff failed (#{inspect(reason)})"
            )
        end
      end)

      notice(ctx, "Handing off #{agent_arg}…")
    end)
  end

  # /context — Claude Code-style snapshot. One line per agent, percentage
  # bar + raw counts, sent as a NOTICE block.
  defp do_handle("CONTEXT", msg, ctx) do
    with_room(msg, ctx, fn _args, room_id ->
      Enum.each(context_report(room_id), &notice(ctx, &1))
    end)
  end

  # --- Verb argument resolution ---

  # Pulls a channel arg or falls back to the user's only joined channel.
  # Calls `fun.(remaining_args, room_id)` on success; emits 461 if no
  # channel can be inferred. Returns :ok regardless (slash verbs don't
  # mutate connection state).
  defp with_room(msg, ctx, fun) do
    args = Protocol.Message.args(msg)
    cmd = msg.command

    case resolve_room_arg(args, ctx) do
      {:ok, room_id, rest} ->
        fun.(rest, room_id)

      {:error, :no_channel} ->
        reply(ctx, Numerics.need_more_params(ctx.server, ctx.nick, cmd))

      {:error, :ambiguous} ->
        notice(ctx, "You're in multiple channels — specify one (#room) as the first argument.")

      {:error, :unknown_channel} ->
        reply(ctx, Numerics.need_more_params(ctx.server, ctx.nick, cmd))
    end

    :ok
  end

  defp with_room_and_agent(msg, ctx, fun) do
    cmd = msg.command

    with_room(msg, ctx, fn rest, room_id ->
      case rest do
        [agent_nick | _] ->
          case Agents.find_in_room(agent_nick, room_id) do
            {:ok, agent_id} ->
              fun.(agent_nick, room_id, agent_id)

            :not_found ->
              reply(ctx, %Protocol.Message{
                prefix: ctx.server,
                command: "401",
                params: [ctx.nick, agent_nick],
                trailing: "No such nick in this room"
              })
          end

        [] ->
          reply(ctx, Numerics.need_more_params(ctx.server, ctx.nick, cmd))
      end
    end)
  end

  defp resolve_room_arg(args, ctx) do
    case args do
      ["#" <> _ = channel | rest] ->
        case Channels.target_to_room_id(ctx.aliases, channel) do
          nil -> {:error, :unknown_channel}
          room_id -> {:ok, room_id, rest}
        end

      _ ->
        case MapSet.to_list(ctx.channels) do
          [] -> {:error, :no_channel}
          [room_id] -> {:ok, room_id, args}
          _ -> {:error, :ambiguous}
        end
    end
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
        roster = Enum.filter(Agents.list(), fn a -> a.id in ids end)

        max_nick =
          roster |> Enum.map(&String.length(NickMap.id_to_nick(&1.id))) |> Enum.max(fn -> 0 end)

        ["Context windows:"] ++
          Enum.map(roster, fn agent ->
            nick = NickMap.id_to_nick(agent.id)
            tokens = agent.current_context_tokens || 0
            window = agent.context_window || 0
            pct = if window > 0, do: round(tokens / window * 100), else: 0
            bar = Format.context_bar(pct)

            "  #{String.pad_trailing(nick, max_nick)}  #{bar}  #{String.pad_leading("#{pct}%", 4)}  " <>
              "(#{Format.int(tokens)} / #{Format.int(window)})"
          end)
    end
  end

  defp reply(ctx, %Protocol.Message{} = m), do: ctx.emit.(Protocol.encode(m))

  defp notice(ctx, text), do: Wire.send_notice(ctx.socket, ctx.server, ctx.nick, text)
end
