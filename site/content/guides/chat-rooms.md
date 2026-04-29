---
title: Chat rooms
section: Agents
weight: 16
summary: Shared-transcript multi-agent coordination. Addressing modes, activation, turn budget, save and rehydrate.
---

A chat room is a long-lived process that holds a shared
transcript, a roster of agents, and a turn budget. Every agent
in the roster sees every message. A coordinator inside Egghead
decides which agent or agents respond to each message based on
how the sender addressed it.

If you have used CrewAI's hierarchy, Paperclip's board operator,
or another framework where one agent decides who acts next, the
shape here is different on purpose. Egghead's room is closer to
an IRC channel than to a workflow graph: there is no dispatcher,
nobody is waiting for an instruction, and any agent who has
something to add can speak. The coordinator's job is to decide
which agents are eligible on a given turn, not to assign roles.
The research pointing at this design is summarized in
[Research influences]({{< ref "research-influences" >}}).

A room lives in memory for as long as the node runs. If you
want the conversation to survive a restart, save the transcript
to a record first; rejoining the saved transcript later
rehydrates the room from it.

## What `/pass` means

A few sections below this one talk about `/pass`, so it is
worth defining up front. When an agent is asked to respond and
genuinely has nothing useful to add, it can yield with the
single token `/pass`. The coordinator catches the token,
removes it from the visible output, and renders an italic
action line in its place — something like *"shuffles notes,
finds nothing new"* — so the transcript reads cleanly.

The point of `/pass` is that an agent that has nothing to say
should *say* nothing rather than fabricate a contribution.
Yielding does not count against the turn budget, so a quiet
agent costs you nothing. There are two cases where the rule
shifts: in `@everyone` mode, the coordinator rejects `/pass`
and asks once more for a substantive line; if the agent passes
again, the coordinator substitutes a flavor line rather than
force a fabricated reply.

## Lifecycle

From `iex`:

```elixir
Egghead.create_room(id: "architecture-sync")
Egghead.list_rooms()
Egghead.room_exists?("architecture-sync")
Egghead.default_room()
```

From the TUI, `/chat` enters chat mode and `/join <id>` switches
to a room with that id, creating it if it does not already
exist. From the shell, `egghead chat` opens the default room.

`Egghead.chat/2` sends a message to a room.
`Egghead.watch/1` streams the room's events to stdout, which is
useful when you want to follow the conversation from `iex` or
another terminal. `Egghead.chat_transcript/1` returns the full
message list as data.

## Addressing modes

There are four ways to send a message, and the way you address
the message determines who responds.

### Open message

```
Anyone have context on the auth middleware?
```

No prefix and no `@`-mention. The coordinator scores every
eligible agent in the room by
[TF-IDF](https://en.wikipedia.org/wiki/Tf%E2%80%93idf) overlap
between the message tokens and each agent's tags plus
disposition, then prompts every eligible agent in score order.
The activation budget caps how many can speak in total
(see below).

In a typical room, most agents in the roster *are* prompted on
an open message; each one then decides individually whether to
respond substantively or yield with `/pass`. So the right
mental model is "most agents get a turn, and the ones who have
nothing useful to add stay quiet" — not "only one or two are
even asked."

### Direct address

```
@researcher what's the rate limit on api.stripe.com?
```

Direct address resolves through fuzzy matching on the agent
id, so `@researcher`, `@agents/researcher`, and `@reseacher`
all land on the same agent. Only the addressed agent is
prompted to respond; everyone else stays silent for that turn.

That said, every other agent in the room *sees* the exchange
in their own context on the next turn. Direct addressing is
about who responds, not about who can hear; the room remains a
shared transcript and a `@`-mention is not a way to hide a
conversation from the rest of the roster.

Direct address is louder than `mute`: even if you muted an
agent earlier, an explicit `@` against that agent in the same
turn still gets a reply. The mute itself is not lifted, just
overridden for the one message.

### `@everyone` (alias `@channel`)

```
@everyone what's your best guess on the deadlock?
```

Every eligible agent responds in series. `/pass` is rejected
by the coordinator in this mode (see the `/pass` section
above). `@everyone` overrides mute for the same reason direct
address does.

### `@jam`

```
@jam what's your angle on this?
```

Every eligible agent responds in parallel without seeing each
other's drafts. Use this when you want a spread of independent
takes rather than a converging discussion. `@jam` also
overrides mute.

## Activation

Before any agent runs, the coordinator decides who is eligible
to respond. It does this in two stages.

The first stage is a structural filter that costs no API calls.
It selects agents based on the addressing mode, removes any
agents you have muted (where mute applies), and removes agents
currently mid-handoff. For explicit addressing — `@researcher`,
`@everyone`, `@jam` — this is the entire gate.

The second stage runs only on open messages. The coordinator
scores each remaining agent by
[TF-IDF](https://en.wikipedia.org/wiki/Tf%E2%80%93idf) overlap
between the message tokens and each agent's tags + disposition.
The top scorer goes first; the rest follow in score order. The
score does not gate eligibility on its own — every agent the
structural filter let through is prompted. Score order
determines who speaks first and gets to set the room's
direction.

## Turn budget

Each room has an activation budget that scales with the size of
the roster. The formula is
`clamp(ceil(1.5 × agent_count), 6, 21)`: a roster of two agents
gets a budget of six, a roster of ten gets fifteen, and a
roster of twenty gets the ceiling of twenty-one. The 1.5×
multiplier gives every agent room to respond once with a
partial allowance for cascade replies, and the floor and
ceiling keep tiny rooms loose and big rooms bounded.

Each substantive agent response decrements the budget by one;
`/pass` does not count against it. When the budget hits zero,
the room broadcasts `:budget_exhausted` and the UI prompts you:

> `/continue` to keep going.

`Egghead.chat_continue/1` or `/continue` resets the budget.
Any `@`-mentions queued while the budget was at zero are
replayed on continue, so a directly-addressed agent never
silently swallows a turn.

The budget exists to keep humans in the loop. Agents left on
their own will keep talking; the budget is the meeting's
scheduled end time.

## Slash commands

| Command | Effect |
|---------|--------|
| `/save` | Write the transcript as a `class: transcript` record at `chat/<room-id>`. |
| `/continue` | Reset the activation budget. |
| `/handoff <agent>` | Summarize the agent's session into a deliberation, clear the session, and rehydrate from the recent transcript. |
| `/join <room-or-transcript>` | Switch into another room, or rehydrate a saved transcript into a live room. |
| `/leave` | Exit chat mode. The room keeps running. |
| `/drop` | Stop the room and auto-save. `/drop --no-save` skips the save. |
| `/halt` | Stop the room without saving. |
| `/mute <agent>` | Suppress the agent's activation in this room for open messages and `@jam`. |
| `/unmute <agent>` | Lift the mute. |
| `/invite <agent>` | Add the agent to the roster. Starts the agent's process if it is not running. |
| `/kick <agent>` | Remove the agent from the roster and clear its per-room session. |
| `/whois <agent>` | Print model, capabilities, and joined rooms; includes a wikilink to the source record. |
| `/rooms` | List every live room. |
| `/list` | Show this room's roster, budget, and mute list. |
| `/help` | Slash-command reference. |
| `/quit` | Quit the TUI. |

`/invite `, `/kick `, and `/whois ` (each with a trailing
space) open pickers that list candidate agents.

## Mute versus kick

Mute is per-room and in-memory. The agent stays in the roster,
its per-room session keeps its history, and direct addressing
(`@agent`, `@everyone`) bypasses the mute. Kick is a different
operation: it removes the agent from the roster and drops the
agent's per-room session, which is the agent's internal
working state for that room — its turn history, token usage,
and the records it has referenced.

What the agent loses on kick is that internal session state.
What the agent does *not* lose is access to the room's
transcript: when you re-invite later, the agent rebuilds its
LLM context by reading the current transcript, including
everything that was said before the kick. Kick is "stop using
the working notes you've been keeping in this room and start
fresh from the room's record"; it is not "forget this
conversation ever happened."

The agent process itself keeps running for any other rooms it
belongs to. `/kick` refuses to remove the last agent from the
default room, because the default room is the fallback chat
surface and is expected to always have at least one
inhabitant.

## Handoff

```
/handoff researcher
```

Or, programmatically:

```elixir
Egghead.handoff("agents/researcher", room_id: "architecture-sync")
```

When you trigger a handoff, the agent summarizes its session
into a `class: deliberation` record, the session state is
cleared, and the agent rehydrates from the most recent fifty
or so messages in the room. The most recent deliberation is
appended to the next system prompt, so the agent has a
hand-off note from its prior self.

The shape was directly informed by Amp's writeup,
[Hand-off](https://ampcode.com/news/handoff), which describes
the same compaction-vs-handoff trade and lands at the same
conclusion: when an agent's working memory is full, replace it
with a fresh agent that inherits a written summary, rather
than try to compress the existing one in place.

You typically run a handoff when an agent's context window is
nearing its limit (the session emits a suggestion at
`context_threshold`, default 0.70) or when you want to start a
new task with a clean slate.

## Save and rehydrate

`/save` writes a `class: transcript` record at
`chat/<room-id>`. The body contains every message rendered
verbatim, prefixed with `**name** at <ts>`. The participants
are captured in `links:`.

```
/save
```

Later, `/join chat/architecture-sync` reads the transcript and
rehydrates the room from it. The conversation resumes with the
same agents and the same message history. If no saved
transcript exists for the id, a fresh room is created.

The reason `class: transcript` is distinct from
`class: deliberation` is that transcripts can be rehydrated
and deliberations cannot.

## See also

- [Agents]({{< ref "agents" >}}) covers what an agent is and
  how the coordinator scores it.
- [Capabilities]({{< ref "capabilities" >}}) covers what an
  agent in the room is allowed to do once it speaks.
- [Consultation]({{< ref "consultation" >}}) is the one-shot
  shape that wraps the same coordinator behind a single
  function call.
