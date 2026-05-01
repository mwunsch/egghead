---
title: IRC server
section: Integrations
weight: 32
summary: Egghead's chat rooms exposed as an IRC server, so your daily IRC client can talk to your agents.
---

Egghead ships an IRC server on the same node as the web UI and the
MCP endpoint. Channels are chat rooms, nicks are agents, and the
slash-command palette you already know from the TUI is the verb set
on the wire. Point ERC, irssi, weechat, or any other RFC 2812-ish
client at `localhost:6667` and you are in.

The reason this exists is that IRC clients are very good at the
shape Egghead's chat rooms already have: a long-lived shared
buffer, terse line-at-a-time messages, multiple participants, a
slash-command convention. The TUI and the web UI already cover
chat — IRC is a third surface for people who already live in an
IRC client and would rather keep their agents in the same buffer
ring as everything else they read all day. Scrollback,
ping-on-mention, message search, log archiving, away tracking,
and the other affordances IRC clients have refined for thirty
years come along for the ride.

The wire is the integration. Anything that speaks RFC 2812
becomes a viable Egghead client without further work on our side.

## Starting the server

The IRC server starts by default whenever `egghead serve` runs.
There is no separate command, no extra flag, and no config block
required for the loopback case:

```bash
egghead serve
```

You should see a log line like:

```
IRC server listening on 127.0.0.1:6667
```

To turn it off, either pass `--no-irc` to `egghead serve`, set
`EGGHEAD_IRC=false` in the environment, or set
`config :egghead, :start_irc, false` at compile time. The shape
mirrors the web server's `--no-web` switch — IRC is just another
network surface attached to the same supervision tree, not a
separate program.

## Connecting

There is one Egghead node and one IRC server per host. Connect
the way you would to any other ircd; the canonical examples:

### ERC (Emacs)

```
M-x erc RET 127.0.0.1 RET 6667 RET <your-nick> RET
```

### irssi

```
/connect 127.0.0.1 6667
```

### weechat

```
/server add egghead 127.0.0.1/6667
/connect egghead
```

### Command-line probe

```bash
nc 127.0.0.1 6667
```

If you just want to see registration handshake at the line
level — `NICK`, `USER`, `001 RPL_WELCOME`, the `005 RPL_ISUPPORT`
chain — `nc` (or any other raw TCP tool) is the fastest way.

## Channels are rooms

Joining a channel joins the underlying chat room. A single special
case is worth knowing up front:

```
/join #default
```

`#default` is a per-connection alias that resolves to whatever your
configured `default_room:` actually is. The server echoes the join
back as `#default` (not the canonical name) so strict clients like
ERC actually open a buffer for it. Every other channel name maps
directly: `/join #architecture-sync` opens or joins the
`architecture-sync` room.

```
/join #architecture-sync       (creates or joins)
/part #architecture-sync       (leaves the room from this connection)
/list                          (lists every live room as channels)
/names #architecture-sync      (roster: agents in the room + you)
```

Rooms are documented at length in
[Chat rooms]({{< ref "chat-rooms" >}}); the IRC mapping is a
straight projection. Joining a saved transcript is the same
operation as in the TUI: `/join #chat-foo` rehydrates if a
`class: transcript` record exists at that id.

## Nicks are agents

A record's id is its pathname inside the records directory, minus
the `.md` extension. An agent record at `~/.egghead/scout.md` has
id `scout`; one at `~/.egghead/agents/scout.md` has id
`agents/scout`. Either layout is fine — Egghead does not impose a
directory convention.

IRC nicks, on the other hand, are constrained by the
[RFC 2812 §2.3.1 nickname grammar](https://datatracker.ietf.org/doc/html/rfc2812#section-2.3.1):
no slashes, ASCII-ish, no leading digits. So the server projects
ids onto the IRC nick form before they hit the wire. The
projection takes the last path segment, replaces invalid
characters with `_`, and truncates to 30 characters:

| Record id          | IRC nick   |
|--------------------|------------|
| `scout`            | `scout`    |
| `agents/scout`     | `scout`    |
| `agents/the.judge` | `the_judge`|
| `cassowary`        | `cassowary`|

The projection is what your client sees and addresses; the full
record id never appears on the wire. Two records whose paths
project to the same nick is a collision the projection layer does
not currently resolve, so if you have both `agents/scout.md` and
`scout.md` in your store, expect surprises and rename one.

The server also marks agent nicks as bots in clients that support
[RPL_WHOISBOT (335)](https://modern.ircdocs.horse/#rplwhoisbot-335).
Clients that don't support it just see a normal user.

## Addressing in channel

The four addressing modes from
[Chat rooms]({{< ref "chat-rooms" >}}) work unchanged. The
coordinator does not care that the message came in over IRC.

```
Anyone have context on the auth middleware?
```

Open message: the structural filter and TF-IDF score determine who
responds, and quiet agents stay quiet by default.

```
@scout what's the rate limit on api.stripe.com?
```

Direct address: only `scout` is prompted. Fuzzy match still
applies (`@scout`, `@agents/scout`, and `@scoot` all land on the
same agent).

```
@everyone what's your best guess on the deadlock?
```

Everyone responds in series; `/pass` is rejected.

```
@jam what's your angle on this?
```

Everyone responds in parallel without seeing each other's drafts.

`@`-mentions inside an IRC `PRIVMSG` use the agent's IRC nick
(without slash namespacing). The coordinator's rules are otherwise
identical.

## Direct messages to an agent

```
/msg scout summarize the last week of meta/session-log
```

A `PRIVMSG` to an agent nick is a 1:1 prompt — `Egghead.prompt/3`,
not a chat-room message. There is no shared transcript, no other
agents see it, and the response comes back as a `PRIVMSG` from
that agent's nick. This is the IRC analogue of `/handoff`-less
ephemeral consultation: handy for a quick lookup that does not
need to clutter a channel.

## Slash-command palette as IRC verbs

The TUI's slash commands are mapped onto native IRC verbs over the
wire. ERC's `/handoff scout` sends `HANDOFF scout`; irssi's
`/save` sends `SAVE`. You get the same muscle memory across both
surfaces.

| IRC verb     | TUI command          | Effect |
|--------------|----------------------|--------|
| `SAVE`       | `/save`              | Persist the room as a `class: transcript` record. |
| `CONTINUE`   | `/continue`          | Reset the activation budget. |
| `HALT`       | `/halt`              | Stop the room without saving. |
| `MUTE <n>`   | `/mute <agent>`      | Suppress an agent's activation in this room. |
| `UNMUTE <n>` | `/unmute <agent>`    | Lift the mute. |
| `HANDOFF <n>`| `/handoff <agent>`   | Summarize and clear the agent's session. |
| `CONTEXT`    | (TUI: per-agent WHOIS) | Print a per-agent context-window snapshot for the room. |

Each verb resolves the target room from the channel buffer it was
issued in; no `#channel` argument is required when there is no
ambiguity. If your client is somehow not in any channel and you
fire a bare `SAVE`, the server replies with the standard
[461 ERR_NEEDMOREPARAMS](https://modern.ircdocs.horse/#errneedmoreparams-461).

`HANDOFF` runs a multi-second LLM summarization call; the verb
returns immediately with `Handing off scout…` and posts a
`NOTICE` when the summary completes.

## Channel ops: KICK and INVITE

```
/kick #architecture-sync scout :stale context
/invite scout #architecture-sync
```

These are the IRC bindings for `Room.kick/2` and `Room.invite/2`,
not the standard "channel ops" verbs from RFC 2812 — Egghead does
not implement channel modes or oper auth, and there are no
privilege checks on either operation. The mapping is documented
in [Chat rooms]({{< ref "chat-rooms" >}}#mute-versus-kick).

`KICK` removes an agent from the roster and drops its per-room
session; `INVITE` adds an agent and starts its process if it is
not running. The agent process keeps running for any other rooms
it belongs to.

## WHOIS

```
/whois scout
```

`WHOIS` against an agent nick packs the model and current context
percentage into the `RPL_WHOISUSER (311)` realname field, the
agent id and tags and capabilities into `RPL_WHOISSERVER (312)`,
joined channels into `RPL_WHOISCHANNELS (319)`, and emits
`RPL_WHOISBOT (335)` so modern clients render the bot marker.

The reason metadata lives in the realname and server-info fields,
rather than in the more obvious `RPL_WHOISSPECIAL (320)`, is that
several major clients hardcode 320 as "is identified to services"
and ignore the trailing text. Packing into 311/312 means the
information actually shows up.

## CHATHISTORY scrollback

If your client negotiates the IRCv3
[server-time](https://ircv3.net/specs/extensions/server-time) and
[batch](https://ircv3.net/specs/extensions/batch) capabilities,
joining a channel replays the most recent fifty messages from the
room transcript with their original timestamps. That makes
scrollback feel real: messages render at the time they were
spoken, not at the time you joined.

For deeper scrollback, the server speaks the
[CHATHISTORY](https://ircv3.net/specs/extensions/chathistory)
verb (LATEST, BEFORE, AFTER, AROUND, BETWEEN). ERC, weechat with
the IRCv3 plugin, and most modern web clients drive it
automatically as you scroll up. The cap is advertised in
`RPL_ISUPPORT` as `CHATHISTORY=<limit>`.

A note on capabilities: clients that did not negotiate
`server-time` get no scrollback replay on `JOIN`, because messages
without a timestamp would render at "now" and look like a
confusing burst of duplicates. That is by design, not a bug; the
client is opting out of the feature it would need to render the
replay correctly.

## Configuration

The full `irc:` block in `config.yml`:

```yaml
irc:
  port: 6667                                      # default 6667
  bind: 127.0.0.1                                 # default 127.0.0.1
  hostname: irc.local                             # default: gethostname()
  password: "{env:EGGHEAD_IRC_PASSWORD}"          # optional shared password
```

Every key is optional. With no `irc:` block at all, the server
starts on `127.0.0.1:6667` with no auth and a hostname derived
from the local system. The `{env:VAR}` substitution behaves the
same way it does in the rest of the configuration file (see
[Configuration]({{< ref "configuration" >}})).

Per-invocation overrides:

| Override                  | Purpose |
|---------------------------|---------|
| `--irc-port <n>`          | Override `irc.port` for one `egghead serve`. |
| `--no-irc`                | Disable the IRC server for one `egghead serve`. |
| `EGGHEAD_IRC_PORT=<n>`    | Same as `--irc-port`. |
| `EGGHEAD_IRC_BIND=<addr>` | Override `irc.bind`. |
| `EGGHEAD_IRC=false`       | Disable the IRC server. |

If a `password` is configured, clients must `PASS` it during
registration before `NICK`/`USER` (see
[RFC 2812 §3.1.1](https://datatracker.ietf.org/doc/html/rfc2812#section-3.1.1)).
Most clients have a server-password setting; ERC asks for it at
connect time, irssi takes it as `-pw`, weechat as `password=`.

## Security

The same posture as the HTTP and MCP surfaces: Egghead does no
per-caller authentication of its own. An IRC client that can reach
the server can read every channel it joins and prompt every
agent. The optional `irc.password` is a single shared secret; it
is `PASS`-style auth, not nickserv, and there are no per-user
ACLs.

There are three safe deployment shapes, in order of preference:

1. **Loopback only** (the default): `bind: 127.0.0.1`. The IRC
   server is reachable only from the same machine. Right for a
   personal laptop.
2. **Trusted network** (tailnet, private VPC, LAN you own):
   `bind: 0.0.0.0` with the network itself doing
   authentication. The same shape covered for the web UI in
   [Running a node]({{< ref "running-a-node" >}}#bind-and-exposure).
3. **Loopback plus a TLS-terminating reverse proxy in front of
   IRC**: possible but not common. The IRC ecosystem usually
   handles TLS in-protocol on port 6697 instead, which Egghead
   does not currently support — see "Limitations" below.

Don't bind `0.0.0.0` to a public interface without one of the
above. Without authentication, an unauthenticated public IRC
endpoint is equivalent to publishing read/write access to your
chat rooms and your agents to anyone who finds the port.

## IRCv3 capabilities

The server advertises the following caps via `CAP LS`:

| Cap            | Effect |
|----------------|--------|
| `server-time`  | Outbound messages carry an `@time=` tag with the original timestamp. |
| `batch`        | Multi-message bursts (CHATHISTORY responses, JOIN replay) are wrapped in `BATCH` envelopes so clients distinguish history from live traffic. |
| `chathistory`  | Server speaks the `CHATHISTORY` verb. |

Anything else clients ask for via `CAP REQ` is rejected with
`CAP NAK`. The server is not pretending to be a full IRCv3
implementation; it negotiates exactly the caps that make
scrollback work correctly and stops there.

## Single-user today

Egghead is a single-user system at the moment, and the IRC server
inherits that. Every connection submits messages as the system
user (`Egghead.User.current/0`); a second connection from a
different human would show up as the same speaker in the
transcript. Multi-user identity is a deliberate non-feature
today, and nothing in the wire protocol forecloses adding it
later when two humans actually want to share an instance.

In practice this means: today, run one IRC connection per Egghead
node. Multiple connections work and the wire protocol is correct,
but the speaker identity is shared.

## Limitations

A few things that exist on the public IRC plane and do not exist
here:

- **No TLS on 6697.** Plaintext only. Loopback or a trusted
  network is the deployment story. ThousandIsland supports SSL
  out of the box, so this is mostly a config wiring exercise if
  it becomes important.
- **No federation, services, oper auth, channel modes, or
  K-lines.** Egghead's IRC is an interface to one instance, not a
  network. The IRCd-as-distributed-system surface is irrelevant
  here.

## See also

- [Chat rooms]({{< ref "chat-rooms" >}}) covers the underlying
  coordination model — addressing, activation, the turn budget,
  mute versus kick — that the IRC layer projects onto the wire.
- [Configuration]({{< ref "configuration" >}}) covers the full
  `config.yml` schema and `{env:VAR}` substitution.
- [Running a node]({{< ref "running-a-node" >}}) covers process
  supervision, network exposure, and the bind-and-exposure
  reasoning that applies equally to the IRC port.
- [MCP server]({{< ref "mcp" >}}) is the other integration
  surface on the same node — same posture, different protocol.
- [RFC 2812](https://datatracker.ietf.org/doc/html/rfc2812) and
  the [Modern IRC client protocol](https://modern.ircdocs.horse/)
  are the authoritative references for the wire protocol and the
  numeric reply codes.
