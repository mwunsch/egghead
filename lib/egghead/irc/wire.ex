defmodule Egghead.IRC.Wire do
  @moduledoc """
  Low-level wire emission helpers — encoding `%Protocol.Message{}`
  structs and writing them to a Thousand Island socket.

  Pulled out of `Connection` so the per-connection module isn't
  carrying the IRC line shaping logic. Higher-level helpers
  (PRIVMSG / NOTICE / CTCP ACTION) take the channel name and tags as
  arguments rather than reaching into connection state — channel
  aliasing and IRCv3 cap negotiation stay in `Connection` /
  `Channels`.
  """

  require Logger

  alias Egghead.IRC.Protocol

  @ctcp_delim <<1>>

  @doc "Write a pre-encoded iodata line to the socket."
  def write(socket, iodata) do
    case ThousandIsland.Socket.send(socket, iodata) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("IRC send failed: #{inspect(reason)}")
    end
  end

  @doc "Encode a `%Protocol.Message{}` and write it."
  def send_message(socket, %Protocol.Message{} = msg) do
    write(socket, Protocol.encode(msg))
  end

  @doc """
  Send a PRIVMSG, splitting `content` on newlines so multi-paragraph
  messages don't drop content. `tags` defaults to `%{}` (no IRCv3
  tags); pass the result of `time_tag/2` to add `@time=`.
  """
  def send_privmsg(socket, from_nick, channel, content, tags \\ %{}) do
    content
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(fn line ->
      write(
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

  @doc """
  Send a CTCP ACTION (the `/me` style line — most clients render as
  `* nick text`). `tags` follows the same convention as `send_privmsg`.
  """
  def send_action(socket, from_nick, channel, text, tags \\ %{}) do
    write(
      socket,
      Protocol.encode(
        tags: tags,
        prefix: from_nick,
        command: "PRIVMSG",
        params: [channel],
        trailing: @ctcp_delim <> "ACTION " <> text <> @ctcp_delim
      )
    )
  end

  @doc """
  Send a NOTICE from `server` to `target` (channel or nick). Splits
  `text` on newlines.
  """
  def send_notice(socket, server, target, text, tags \\ %{}) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(fn line ->
      write(
        socket,
        Protocol.encode(
          tags: tags,
          prefix: server,
          command: "NOTICE",
          params: [target],
          trailing: line
        )
      )
    end)
  end

  @doc """
  IRCv3 `server-time` tag map. Returns `%{}` if the client didn't
  negotiate the cap (so the encoder emits no tag prefix at all),
  else `%{"time" => ISO-8601}`. Pass an explicit `DateTime` for
  historical messages (scrollback replay); otherwise defaults to now.
  """
  def time_tag(caps, dt \\ nil) do
    if MapSet.member?(caps, "server-time") do
      iso = (dt || DateTime.utc_now()) |> DateTime.to_iso8601()
      %{"time" => iso}
    else
      %{}
    end
  end

  @doc "RFC-style hostmask prefix `nick!user@host` — falls back to nick if user is nil."
  def prefix(nick, user, host), do: "#{nick}!#{user || nick}@#{host}"

  @doc """
  Synthetic prefix for events sourced from agents (no real socket).
  `nick!egghead@server` is recognizable, validates as a hostmask, and
  makes it clear this isn't a human peer.
  """
  def agent_prefix(nick, server), do: "#{nick}!egghead@#{server}"
end
