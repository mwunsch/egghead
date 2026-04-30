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

  @doc "311 RPL_WHOISUSER — nick / user / host / realname for a WHOIS reply."
  def whois_user(server, asker, nick, user, host, realname) do
    %Message{
      prefix: server,
      command: "311",
      params: [asker, nick, user, host, "*"],
      trailing: realname
    }
  end

  @doc "312 RPL_WHOISSERVER — server name + info for a WHOIS reply."
  def whois_server(server, asker, nick, server_name, info) do
    %Message{
      prefix: server,
      command: "312",
      params: [asker, nick, server_name],
      trailing: info
    }
  end

  @doc "317 RPL_WHOISIDLE — idle seconds + signon timestamp."
  def whois_idle(server, asker, nick, idle_seconds, signon_epoch) do
    %Message{
      prefix: server,
      command: "317",
      params: [asker, nick, Integer.to_string(idle_seconds), Integer.to_string(signon_epoch)],
      trailing: "seconds idle, signon time"
    }
  end

  @doc "318 RPL_ENDOFWHOIS — terminates a WHOIS burst."
  def end_of_whois(server, asker, nick) do
    %Message{
      prefix: server,
      command: "318",
      params: [asker, nick],
      trailing: "End of WHOIS list"
    }
  end

  @doc "319 RPL_WHOISCHANNELS — list of channels the nick is in."
  def whois_channels(server, asker, nick, channels) when is_list(channels) do
    %Message{
      prefix: server,
      command: "319",
      params: [asker, nick],
      trailing: Enum.join(channels, " ")
    }
  end

  @doc """
  320 RPL_WHOISSPECIAL — nominally "free-form info," but in practice
  many clients (ERC, hexchat) hard-code it as "is identified to
  services" regardless of trailing text. Avoid for arbitrary metadata;
  use realname (311) or bot marker (335) instead. Kept for callers
  that have a use for the literal-services semantic.
  """
  def whois_special(server, asker, nick, line) do
    %Message{prefix: server, command: "320", params: [asker, nick], trailing: line}
  end

  @doc "335 RPL_WHOISBOT — modern marker rendered distinctly by current clients."
  def whois_bot(server, asker, nick, network \\ "Egghead") do
    %Message{
      prefix: server,
      command: "335",
      params: [asker, nick],
      trailing: "is a bot on #{network}"
    }
  end

  @doc "341 RPL_INVITING — confirms an INVITE was sent."
  def inviting(server, asker, target_nick, channel) do
    %Message{prefix: server, command: "341", params: [asker, target_nick, channel]}
  end

  @doc "351 RPL_VERSION — server version string."
  def version_reply(server, asker, version, comments) do
    %Message{
      prefix: server,
      command: "351",
      params: [asker, version, server],
      trailing: comments
    }
  end

  @doc "372 RPL_MOTD — one line of the MOTD (server convention prefixes `- `)."
  def motd(server, nick, line) do
    %Message{prefix: server, command: "372", params: [nick], trailing: "- " <> line}
  end

  @doc "375 RPL_MOTDSTART — header for the MOTD burst."
  def motd_start(server, nick) do
    %Message{
      prefix: server,
      command: "375",
      params: [nick],
      trailing: "- #{server} Message of the day -"
    }
  end

  @doc "376 RPL_ENDOFMOTD — terminator for MOTD burst."
  def end_of_motd(server, nick) do
    %Message{prefix: server, command: "376", params: [nick], trailing: "End of /MOTD command"}
  end

  @doc "391 RPL_TIME — server local time."
  def time_reply(server, nick, time_string) do
    %Message{prefix: server, command: "391", params: [nick, server], trailing: time_string}
  end

  @doc "401 ERR_NOSUCHNICK — nick (or channel) doesn't exist."
  def no_such_nick(server, asker, target) do
    %Message{
      prefix: server,
      command: "401",
      params: [asker, target],
      trailing: "No such nick/channel"
    }
  end

  @doc "442 ERR_NOTONCHANNEL — issuer isn't on the target channel."
  def not_on_channel(server, asker, channel) do
    %Message{
      prefix: server,
      command: "442",
      params: [asker, channel],
      trailing: "You're not on that channel"
    }
  end

  @doc "443 ERR_USERONCHANNEL — INVITE target is already in the channel."
  def user_on_channel(server, asker, target_nick, channel) do
    %Message{
      prefix: server,
      command: "443",
      params: [asker, target_nick, channel],
      trailing: "is already on channel"
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
