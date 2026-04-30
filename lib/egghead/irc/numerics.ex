defmodule Egghead.IRC.Numerics do
  @moduledoc """
  IRC numeric reply codes (RFC 2812 §5).

  Helpers that build pre-shaped `%Egghead.IRC.Protocol.Message{}` structs
  for the most common server replies. Connection handlers use these
  instead of hand-assembling each reply, so the wire format stays
  consistent and the call sites read close to the RFC.

  Every server-originated message takes a `nick` argument as the first
  parameter — that's RFC-required (the recipient's nick is always echoed
  back). For pre-registration replies, callers pass `"*"` per convention.
  """

  alias Egghead.IRC.Protocol.Message

  @doc "001 RPL_WELCOME — sent immediately after registration completes."
  def welcome(server, nick, network \\ "Egghead") do
    %Message{
      prefix: server,
      command: "001",
      params: [nick],
      trailing: "Welcome to the #{network} IRC Network #{nick}"
    }
  end

  @doc "002 RPL_YOURHOST — server identification string."
  def your_host(server, nick, version) do
    %Message{
      prefix: server,
      command: "002",
      params: [nick],
      trailing: "Your host is #{server}, running version #{version}"
    }
  end

  @doc "003 RPL_CREATED — server boot time string."
  def created(server, nick, since) when is_binary(since) do
    %Message{
      prefix: server,
      command: "003",
      params: [nick],
      trailing: "This server was created #{since}"
    }
  end

  @doc """
  004 RPL_MYINFO — server name, version, user modes, channel modes.
  We expose no user modes and a tiny channel mode set today (`m` mute);
  the parameter is informational and clients mostly ignore it.
  """
  def my_info(server, nick, version) do
    %Message{
      prefix: server,
      command: "004",
      params: [nick, server, version, "", "m"]
    }
  end

  @doc """
  005 RPL_ISUPPORT — capabilities the server advertises. Clients use
  this to size buffers and decide which features to enable.

  Each parameter token is a `KEY` or `KEY=value` pair; the trailing
  string `are supported by this server` is RFC convention.
  """
  def isupport(server, nick, tokens) when is_list(tokens) do
    %Message{
      prefix: server,
      command: "005",
      params: [nick] ++ tokens,
      trailing: "are supported by this server"
    }
  end

  @doc """
  353 RPL_NAMREPLY — one chunk of the NAMES list for a channel.

  `members` is a list of nicks. Agent nicks should arrive with their
  prefix already attached (e.g. `+scout` for voice). The `=` between
  nick and channel marks the channel as public (vs. `*` secret, `@` private).
  """
  def names_reply(server, nick, channel, members) when is_list(members) do
    %Message{
      prefix: server,
      command: "353",
      params: [nick, "=", channel],
      trailing: Enum.join(members, " ")
    }
  end

  @doc "366 RPL_ENDOFNAMES — terminates a NAMES burst."
  def end_of_names(server, nick, channel) do
    %Message{
      prefix: server,
      command: "366",
      params: [nick, channel],
      trailing: "End of /NAMES list"
    }
  end

  @doc "221 RPL_UMODEIS — user's current mode flags (we expose none)."
  def user_mode_is(server, nick) do
    %Message{prefix: server, command: "221", params: [nick, "+"]}
  end

  @doc "331 RPL_NOTOPIC — channel exists but has no topic set."
  def no_topic(server, nick, channel) do
    %Message{prefix: server, command: "331", params: [nick, channel], trailing: "No topic is set"}
  end

  @doc "332 RPL_TOPIC — current topic of the channel."
  def topic_reply(server, nick, channel, topic) do
    %Message{prefix: server, command: "332", params: [nick, channel], trailing: topic}
  end

  @doc "333 RPL_TOPICWHOTIME — non-RFC-2812 but widely supported: who set the topic and when."
  def topic_who_time(server, nick, channel, setter, epoch) do
    %Message{
      prefix: server,
      command: "333",
      params: [nick, channel, setter, Integer.to_string(epoch)]
    }
  end

  @doc """
  321 RPL_LISTSTART — header line for a LIST reply burst. Most modern
  clients ignore this and only consume RPL_LIST entries, but RFC 2812
  expects it.
  """
  def list_start(server, nick) do
    %Message{
      prefix: server,
      command: "321",
      params: [nick, "Channel", "Users"],
      trailing: "Name"
    }
  end

  @doc "322 RPL_LIST — one channel in a LIST reply (#channel, user count, topic)."
  def list_entry(server, nick, channel, user_count, topic) do
    %Message{
      prefix: server,
      command: "322",
      params: [nick, channel, Integer.to_string(user_count)],
      trailing: topic || ""
    }
  end

  @doc "323 RPL_LISTEND — terminates a LIST burst."
  def list_end(server, nick) do
    %Message{prefix: server, command: "323", params: [nick], trailing: "End of /LIST"}
  end

  @doc """
  324 RPL_CHANNELMODEIS — current modes on a channel. We don't expose
  any channel modes today (mute is per-agent and handled at the
  Coordinator level), so the mode string is always `+`.
  """
  def channel_mode_is(server, nick, channel) do
    %Message{prefix: server, command: "324", params: [nick, channel, "+"]}
  end

  @doc "329 RPL_CREATIONTIME — channel creation epoch (Unix seconds)."
  def creation_time(server, nick, channel, epoch) do
    %Message{
      prefix: server,
      command: "329",
      params: [nick, channel, Integer.to_string(epoch)]
    }
  end

  @doc "421 ERR_UNKNOWNCOMMAND — server doesn't recognize the verb."
  def unknown_command(server, nick, command) do
    %Message{
      prefix: server,
      command: "421",
      params: [nick, command],
      trailing: "Unknown command"
    }
  end

  @doc "431 ERR_NONICKNAMEGIVEN — NICK with no argument."
  def no_nickname_given(server, nick) do
    %Message{prefix: server, command: "431", params: [nick], trailing: "No nickname given"}
  end

  @doc "432 ERR_ERRONEUSNICKNAME — NICK with invalid characters."
  def erroneus_nickname(server, nick, attempted) do
    %Message{
      prefix: server,
      command: "432",
      params: [nick, attempted],
      trailing: "Erroneous nickname"
    }
  end

  @doc "433 ERR_NICKNAMEINUSE — NICK collides with a connected client or agent."
  def nickname_in_use(server, nick, attempted) do
    %Message{
      prefix: server,
      command: "433",
      params: [nick, attempted],
      trailing: "Nickname is already in use"
    }
  end

  @doc "451 ERR_NOTREGISTERED — caller hasn't completed NICK + USER yet."
  def not_registered(server) do
    %Message{prefix: server, command: "451", params: ["*"], trailing: "You have not registered"}
  end

  @doc "461 ERR_NEEDMOREPARAMS — command was missing required arguments."
  def need_more_params(server, nick, command) do
    %Message{
      prefix: server,
      command: "461",
      params: [nick, command],
      trailing: "Not enough parameters"
    }
  end

  @doc "462 ERR_ALREADYREGISTERED — second USER attempt after registration."
  def already_registered(server, nick) do
    %Message{
      prefix: server,
      command: "462",
      params: [nick],
      trailing: "Unauthorized command (already registered)"
    }
  end

  @doc "464 ERR_PASSWDMISMATCH — PASS missing or wrong."
  def passwd_mismatch(server) do
    %Message{prefix: server, command: "464", params: ["*"], trailing: "Password incorrect"}
  end
end
