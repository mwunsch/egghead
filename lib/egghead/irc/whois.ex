defmodule Egghead.IRC.Whois do
  @moduledoc """
  WHOIS handling.

  WHOIS for an agent packs model + context % into 311's realname,
  tags + capabilities into 312's server-info, walks the agent's room
  memberships for 319, and emits 335 RPL_WHOISBOT to mark the nick as
  a bot in modern clients. WHOIS for a connected human returns 311 +
  312 only — joined-channels for humans needs a per-conn-room reverse
  index in `Egghead.IRC.Registry`.

  Wire emission goes through an `emit` callback the connection passes
  in, mirroring the `ChatHistory` shape.
  """

  alias Egghead.IRC.{Protocol, Numerics, Registry, Agents}

  @doc """
  Dispatch a parsed `WHOIS` message. `ctx` is:

      %{server: state.server, nick: state.nick, emit: fn iodata -> ... end}
  """
  def handle(%Protocol.Message{} = msg, ctx) do
    case Protocol.Message.args(msg) do
      [target | _] ->
        cond do
          agent = Agents.find_by_nick(target) -> agent_reply(target, agent, ctx)
          Registry.whereis(target) != nil -> human_reply(target, ctx)
          true -> reply(ctx, Numerics.no_such_nick(ctx.server, ctx.nick, target))
        end

        reply(ctx, Numerics.end_of_whois(ctx.server, ctx.nick, target))

      [] ->
        reply(ctx, Numerics.need_more_params(ctx.server, ctx.nick, "WHOIS"))
    end

    :ok
  end

  defp agent_reply(nick, agent, ctx) do
    # Pack metadata into the realname (311) and server-info (312)
    # fields, which clients render verbatim. Avoid 320 RPL_WHOISSPECIAL
    # — ERC and several other clients hardcode it as "is identified to
    # services" regardless of trailing text. 335 RPL_WHOISBOT marks
    # agents distinctly in modern clients.
    #
    # NOTE: deliberately not surfacing `agent.disposition`. That field
    # is `record.body || ""` (see `lib/egghead/record/agent.ex`) — i.e.
    # the whole system prompt, multi-paragraph. Client renderers wrap
    # it across many lines. Tags and capabilities are short labels
    # that fit on one line each.
    ctx_tokens = agent.current_context_tokens || 0
    window = agent.context_window || 0
    pct = if window > 0, do: round(ctx_tokens / window * 100), else: 0

    realname =
      [agent.name, agent.model || "no model", "context #{pct}%"]
      |> Enum.join(" · ")

    info =
      ["Egghead agent · #{agent.id}"]
      |> maybe_append(format_tags(agent.tags), fn t -> "tags: #{t}" end)
      |> maybe_append(format_caps(agent.capabilities), fn c -> "caps: #{c}" end)
      |> Enum.join(" · ")

    reply(ctx, Numerics.whois_user(ctx.server, ctx.nick, nick, "agent", ctx.server, realname))
    reply(ctx, Numerics.whois_server(ctx.server, ctx.nick, nick, ctx.server, info))

    case Agents.channels(agent.id) do
      [] -> :ok
      chans -> reply(ctx, Numerics.whois_channels(ctx.server, ctx.nick, nick, chans))
    end

    reply(ctx, Numerics.whois_bot(ctx.server, ctx.nick, nick))
  end

  defp human_reply(nick, ctx) do
    reply(ctx, Numerics.whois_user(ctx.server, ctx.nick, nick, "user", ctx.server, nick))

    reply(
      ctx,
      Numerics.whois_server(ctx.server, ctx.nick, nick, ctx.server, "Egghead human user")
    )
  end

  defp reply(ctx, %Protocol.Message{} = m), do: ctx.emit.(Protocol.encode(m))

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
end
