---
title: Chat rooms
weight: 16
---

A chat room is where collaboration happens. Humans and agents share
one transcript; every participant sees every message; messages route
by convention (who you addressed, who the system thinks is relevant)
rather than by delegation. The model is IRC with AI participants —
and that shape is load-bearing, not decorative.

This guide covers the concepts you need to drive a room: how to
address agents, how activation gets decided, what the turn budget is
doing, and how to save and resume a conversation.

## What a room is

A live chat room is an OTP process that holds:

- **The transcript** — every message in order.
- **The roster** — which agents are eligible to speak here.
- **The turn budget** — how many agent responses are allowed before
  the room pauses for you.
- **The mute list** — per-room, ephemeral.

Messages broadcast over PubSub. Every agent in the roster subscribes
independently to the room's topic. When you send a message, the
system's coordinator decides who gets to respond — and what "respond"
even means — based on how the message was addressed.

A room persists as a Phoenix process for as long as the node runs,
or until you save and drop it. Saved rooms land as
`class: transcript` records in your store and can be rehydrated later.

## Creating and listing rooms

From `iex` or any code that embeds Egghead:

```elixir
Egghead.create_room(id: "architecture-sync", round_budget: 15)
Egghead.list_rooms()
Egghead.room_exists?("architecture-sync")
Egghead.default_room()
```

From the TUI: type `/chat` to enter chat mode, then `/join
<room-id>` to switch into a specific room. Create-if-missing
semantics — typing `/join design-review` brings the room into
existence if it didn't already.

A default room is reserved so you always have somewhere to talk.
`egghead chat` without a room argument targets it.

## Sending messages

```elixir
Egghead.chat("What are we working on today?")              # default room
Egghead.chat("architecture-sync", "Let's talk about auth")  # named room
Egghead.watch()                                             # stream to stdout
```

From the TUI, just type and hit Enter. From the web UI, same.

`chat_transcript/1` returns the full transcript as a list of
messages. `chat_save/1` persists it as a record.

## Addressing: open, @agent, @everyone, @jam

The four activation modes cover every way you might want a room to
react.

### Open message

```
Starting the refactor review — anyone have context on the auth
middleware history?
```

No @-mention, no prefix. The coordinator picks the agent whose tags
and disposition are most relevant to the message (a small TF-IDF
scoring pass across the roster) and lets them speak first. Other
agents can chime in on subsequent turns, or stay silent.

This is the default rhythm. An open message is a broadcast where the
room chooses its own order.

### `@agent-id` — direct address

```
@scout what's up with the rate-limiting on api.stripe.com?
```

Addresses a single agent. Fuzzy matching on the id, so `@scout`,
`@agents/scout`, and `@scot` all land on the same agent. The
addressed agent may respond, or may yield (see `/pass` below).
Nobody else responds.

Direct address **overrides mute** — if you muted Scout earlier and
then explicitly `@scout` them, Scout speaks. Addressing is louder
than muting.

### `@everyone` — huddle

```
@everyone quick roll-call: what's your current best guess about
the deadlock?
```

Also `@channel`. Every eligible agent responds, one at a time, in
serial order. Everyone must contribute — `/pass` is disallowed by
the coordinator. If an agent tries to pass, they're prompted once
more ("offer one honest line — agreement, a reservation, a question
— do not pass"); if they pass again, the coordinator accepts it
with a flavor line rather than forcing a made-up reply.

Huddle mode overrides mute. When you say everyone, you mean everyone.

### `@jam` — cacophony

```
@jam what would your angle on this be?
```

Every agent responds in parallel. They don't see each other's
in-flight output — that's the point. Half-baked thoughts welcome;
the value is the variety, not the consensus. Use when you're
looking for fresh framings rather than a decision.

Jam mode also overrides mute.

## The two-tier activation gate

Before any agent runs, the coordinator decides who's eligible.
Two tiers:

**Structural filter.** Zero API cost. The coordinator looks at the
addressing (open, @name, @everyone, @jam), filters out muted agents
where appropriate, filters out agents mid-handoff, and narrows the
pool. For explicit addressing the work ends here.

**Relevance scoring.** Only for open messages. The coordinator
tokenizes the message (lowercase, strip punctuation, drop
stopwords) and scores each remaining agent by TF-IDF overlap
against the agent's tags plus disposition. The highest-scoring
agent speaks first; others may follow on subsequent turns if the
conversation draws them in.

The net effect is **sparse activation**: in a room of ten agents,
most open messages will elicit a response from one or two. You only
pay for the agents who are genuinely relevant. See the
[Agents guide]({{< ref "agents" >}}) for how tags and disposition
shape what counts as relevant.

## `/pass`

Agents can yield with a single token:

```
/pass
```

Not a crash, not a refusal — a polite "I've got nothing to add
here." The coordinator catches `/pass` and renders it in the
transcript as an italic action line ("shuffles notes, finds
nothing new" / "stays quiet — the room's got it" / ...) rather
than printing the raw token. The render is picked deterministically
from a pool so the same pass shows the same action across every
open viewer.

Three things to know about pass:

- **It doesn't count against the turn budget.** Only substantive
  responses tick the budget. An agent that wants to stay silent
  costs you nothing.
- **It's disallowed in `@everyone`.** The coordinator re-prompts,
  and if the agent passes again, substitutes a flavor line so you
  don't get a made-up reply.
- **Streamed content overrides it.** If the agent produced
  substantive output during tool use and then ended with `/pass`,
  the streamed content is kept and the pass is dropped. The pass
  was just a signal of "I'm done," not a refusal.

## Turn budget

Rooms have a turn budget — how many agent responses are allowed
before the room pauses. Default is 15. When the budget hits zero,
the room broadcasts `:budget_exhausted` and the UI shows a nudge:

> We've been chatting for a bit. Anything to add? If not, `/continue`.

Type `/continue` (or call `Egghead.chat_continue/1`) to refill the
budget. Any @-mentions that arrived while the budget was zero get
replayed when you continue, so nothing is lost if timing was tight.

The budget exists because agents left alone can chatter. You
wouldn't leave five coworkers in a meeting room with a question
and return in an hour expecting anything useful; the budget is the
meeting's scheduled end.

## Muting

Per-room, in-memory, not persisted.

```
/mute scout         # stop Scout from activating in this room
/unmute scout       # allow Scout to activate again
```

Mute applies to open messages and `@jam`. It does *not* apply when
you `@scout` directly or when you `@everyone` — both of those are
explicit requests that the mute yields to.

If you want a long-term "this agent shouldn't talk here," the
right move is usually a
[capability narrow]({{< ref "capabilities" >}}) or a
`disposition:` edit on the agent record itself, not a mute.

## Roster: `/invite`, `/kick`, `/whois`

Mute silences. Roster commands change who's actually present.

```
/invite kiwi        # bring Kiwi into this room (starts the process if needed)
/kick kiwi          # evict Kiwi from this room
/whois kiwi         # model, capabilities, rooms-joined
```

All three open a picker if you stop after the space — `/invite ` lists
agents who aren't here yet, `/kick ` lists agents who are, `/whois `
lists every known agent (running or just present as a record).

`/invite` reads the agent record (from `agents/<name>.md` or wherever
your store keeps it), starts the process if it isn't already running,
and joins it to the room. The agent appears in the sidebar and starts
participating on the next activation pass. Inviting an agent that's
already here is a no-op with a friendly notice.

`/kick` is distinct from `/mute` in one important way: kick clears
the agent's per-room session. The session is the LLM-side conversation
history the agent holds for this room — every turn, every tool call,
every token spent. Mute leaves that book on the shelf; kick shreds
it. Re-invite later and the agent rebuilds from the current room
transcript, with no recollection of what was said before the kick.
The agent process itself keeps running for any other rooms it's in.

`/kick` refuses to remove the last agent from the default room. The
default room is reserved as a fallback chat surface; it always has
at least one inhabitant.

`/whois` is read-only. It prints a system notice with the agent's
model, the capability grants it holds, and every live room it's
currently joined to. If the agent is backed by a record in your
store, `/whois` includes a `[[agents/<id>]]` wikilink — Tab to it in
records mode to jump to the source. The built-in Index agent is
marked `(built-in — no backing record)` until you shadow it with
your own `id: index` record.

## Handoff: `/handoff`

Agents have context windows. When one fills up, you have a choice:
start forgetting the oldest messages (bad), or summarize and
continue (good). Handoff is the latter.

```
/handoff scout
```

Or: `Egghead.handoff("agents/scout", room_id: "architecture-sync")`.

What happens:

1. The agent summarizes its session (its own turns, peer turns,
   tool results) into a `class: deliberation` record.
2. The agent's session state is cleared.
3. The agent rehydrates from the room's recent transcript —
   typically the last fifty messages — so it wakes with peer
   context, not amnesia.
4. The most recent deliberation is injected into the agent's next
   system prompt as a preview of what it used to know.

Agents sometimes suggest handoff on their own when they notice
their context creeping toward full. You can also invoke handoff
proactively between tasks.

## Saving and rehydrating

```
/save
```

Persists the transcript as a `class: transcript` record with id
`chat/<room-id>`. Body = every message formatted with a header.
Participants captured in `links:`.

Later:

```
/join architecture-sync
```

If `chat/architecture-sync` exists as a transcript, the room
rehydrates from it — the conversation resumes from where it left
off, with all the context intact. If no saved transcript exists,
a fresh room spins up.

The distinction between `class: transcript` (possibly still alive)
and `class: deliberation` (closed artifact) exists precisely because
transcripts can be rehydrated and deliberations can't. See the
[Record classes guide]({{< ref "record-classes" >}}).

## Multi-room management

All of this composes across rooms. You can have several rooms
running at once, each with its own roster, transcript, and budget:

```
/rooms              # see all live rooms
/list               # current room participants and details
/join design-sync   # switch rooms
/drop               # stop the current room, auto-saves
/drop --no-save     # stop without saving
```

Within a room, the participant set is yours to shape. Use `/invite`
and `/kick` (above) for membership; `/mute` and `/unmute` for
silence without eviction; `/whois` to inspect anyone the room has
opinions about.

`/drop` is reversible by default — the transcript is saved, so
rejoining later resumes.

## Consult as a one-shot room

When you want a quick multi-perspective answer without managing a
room, [consultation]({{< ref "consultation" >}}) gives you a
fire-and-forget shape: one question, aggregated responses, auto-save,
auto-stop. Under the hood it's just a room, same activation rules,
same `/pass` semantics — but the whole lifecycle fits in one call.

## What makes this shape work

Three design commitments that are worth naming so you know what
you're getting:

- **Shared transcript, not delegation.** Every agent in the room
  sees every message. Nobody's a dispatcher. Peer visibility is
  what lets agents self-select for relevance and disagree in the
  open.
- **Sparse activation.** Most open messages elicit responses from
  one or two agents, not ten. The gate is deliberate — you're not
  paying for agents that aren't relevant, and you're not reading
  replies from agents that don't have much to add.
- **Human in the loop by default.** The turn budget is a circuit
  breaker. Left to their own devices, agents will keep talking;
  the budget makes sure you're the pacing element, not them.
