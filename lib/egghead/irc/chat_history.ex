defmodule Egghead.IRC.ChatHistory do
  @moduledoc """
  IRCv3 [chathistory](https://ircv3.net/specs/extensions/chathistory)
  extension. Five subcommands:

      CHATHISTORY LATEST  <target> *                       <limit>
      CHATHISTORY BEFORE  <target> timestamp=<iso>         <limit>
      CHATHISTORY AFTER   <target> timestamp=<iso>         <limit>
      CHATHISTORY AROUND  <target> timestamp=<iso>         <limit>
      CHATHISTORY BETWEEN <target> timestamp=<iso> timestamp=<iso> <limit>

  Response: a `BATCH +<id> chathistory <target>` envelope wrapping
  one PRIVMSG per matching transcript message (each tagged with
  `@time=<iso>` and `@batch=<id>`), terminated by `BATCH -<id>`.
  Failures surface as `FAIL CHATHISTORY <code> :<desc>`.

  Pulled out of `Connection` so the chathistory subprotocol lives on
  its own. Wire emission goes through small callbacks the connection
  passes in (`emit_line` and `time_tag`), keeping this module ignorant
  of sockets and IRCv3 cap negotiation.
  """

  alias Egghead.IRC.{Protocol, Numerics, NickMap, Channels}
  alias Egghead.Chat.Room

  @max 100

  @doc "Cap on a single CHATHISTORY response (also the ISUPPORT advertisement)."
  def max, do: @max

  @doc """
  Dispatch a parsed `CHATHISTORY` message. `ctx` is a small bundle:

      %{
        server: state.server,
        nick: state.nick,
        aliases: state.aliases,
        emit: fn iodata -> ... end,    # write a wire line
        time_tag: fn DateTime.t() | nil -> map  # IRCv3 server-time
      }
  """
  def handle(%Protocol.Message{} = msg, ctx) do
    case Protocol.Message.args(msg) do
      [subcommand | rest] ->
        do_dispatch(String.upcase(subcommand), rest, ctx)

      [] ->
        fail(ctx, "NEED_MORE_PARAMS", [], "CHATHISTORY needs a subcommand")
    end

    :ok
  end

  defp do_dispatch("LATEST", [target, _selector, limit_str | _], ctx) do
    window(ctx, target, limit_str, fn _msg -> true end, :latest)
  end

  defp do_dispatch("BEFORE", [target, ts_arg, limit_str | _], ctx) do
    case parse_ts(ts_arg) do
      {:ok, ts} ->
        window(
          ctx,
          target,
          limit_str,
          fn m -> DateTime.compare(m.timestamp, ts) == :lt end,
          :latest
        )

      :error ->
        fail(ctx, "INVALID_PARAMS", [target], "BEFORE needs timestamp=<iso8601>")
    end
  end

  defp do_dispatch("AFTER", [target, ts_arg, limit_str | _], ctx) do
    case parse_ts(ts_arg) do
      {:ok, ts} ->
        window(
          ctx,
          target,
          limit_str,
          fn m -> DateTime.compare(m.timestamp, ts) == :gt end,
          :earliest
        )

      :error ->
        fail(ctx, "INVALID_PARAMS", [target], "AFTER needs timestamp=<iso8601>")
    end
  end

  defp do_dispatch("AROUND", [target, ts_arg, limit_str | _], ctx) do
    case parse_ts(ts_arg) do
      {:ok, ts} ->
        limit = clamp_limit(limit_str)
        half = max(div(limit, 2), 1)

        emit(ctx, target, fn msgs ->
          {before, after_} =
            Enum.split_with(msgs, fn m -> DateTime.compare(m.timestamp, ts) != :gt end)

          (Enum.take(before, -half) ++ Enum.take(after_, half))
          |> Enum.take(limit)
        end)

      :error ->
        fail(ctx, "INVALID_PARAMS", [target], "AROUND needs timestamp=<iso8601>")
    end
  end

  defp do_dispatch("BETWEEN", [target, ts1_arg, ts2_arg, limit_str | _], ctx) do
    with {:ok, ts1} <- parse_ts(ts1_arg),
         {:ok, ts2} <- parse_ts(ts2_arg) do
      {lo, hi} = if DateTime.compare(ts1, ts2) == :lt, do: {ts1, ts2}, else: {ts2, ts1}

      window(
        ctx,
        target,
        limit_str,
        fn m ->
          DateTime.compare(m.timestamp, lo) != :lt and
            DateTime.compare(m.timestamp, hi) != :gt
        end,
        :earliest
      )
    else
      _ ->
        fail(ctx, "INVALID_PARAMS", [target], "BETWEEN needs two timestamp=<iso8601> args")
    end
  end

  defp do_dispatch(sub, args, ctx) do
    target = List.first(args, "*")
    fail(ctx, "UNKNOWN_COMMAND", [target], "CHATHISTORY #{sub} is not supported")
  end

  # `which` is `:latest` (closest to "now") or `:earliest` (closest to
  # the filter's pivot).
  defp window(ctx, target, limit_str, filter, which) do
    limit = clamp_limit(limit_str)

    emit(ctx, target, fn msgs ->
      filtered = Enum.filter(msgs, filter)

      case which do
        :latest -> Enum.take(filtered, -limit)
        :earliest -> Enum.take(filtered, limit)
      end
    end)
  end

  # Resolve target → room, fetch transcript, run selector, emit a
  # BATCH-wrapped sequence of PRIVMSGs.
  defp emit(ctx, target, selector) do
    case Channels.target_to_room_id(ctx.aliases, target) do
      nil ->
        fail(ctx, "INVALID_TARGET", [target], "Unknown channel")

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
          send_batch(ctx, target, room_id, selected)
        else
          fail(ctx, "INVALID_TARGET", [target], "Channel does not exist")
        end
    end
  end

  defp send_batch(ctx, target, room_id, msgs) do
    batch_id = batch_id()

    ctx.emit.(
      Protocol.encode(
        prefix: ctx.server,
        command: "BATCH",
        params: ["+" <> batch_id, "chathistory", target]
      )
    )

    Enum.each(msgs, fn msg -> send_line(ctx, room_id, batch_id, msg) end)

    ctx.emit.(Protocol.encode(prefix: ctx.server, command: "BATCH", params: ["-" <> batch_id]))
  end

  defp send_line(ctx, room_id, batch_id, msg) do
    nick =
      case msg.sender.type do
        :user -> msg.sender.name
        :agent -> NickMap.id_to_nick(msg.sender.id)
      end

    channel = Channels.display_channel(ctx.aliases, room_id)

    tags =
      ctx.time_tag.(msg.timestamp)
      |> Map.put("batch", batch_id)

    msg.content
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(fn line ->
      ctx.emit.(
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

  defp parse_ts("timestamp=" <> iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_ts(_), do: :error

  defp clamp_limit(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> min(n, @max)
      _ -> @max
    end
  end

  defp clamp_limit(_), do: @max

  defp batch_id, do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

  defp fail(ctx, code, context, description) do
    ctx.emit.(
      Protocol.encode(Numerics.fail(ctx.server, "CHATHISTORY", code, context, description))
    )
  end
end
