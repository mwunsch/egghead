---
title: Consultation
weight: 32
---

Consultation is the one-shot shape: ask your agents a question, get
each of their takes back as a structured result, let the system save
the transcript for you. No room management, no `/continue`, no
`/drop` — spin up, collect, tear down.

This guide covers when to reach for consultation versus a live chat
room, how the API is shaped, and what the MCP tool does for external
clients.

## The shape

```elixir
{:ok, result} = Egghead.consult("What's the failure mode if we drop autovacuum?")

result.responses
# => [
#   %{agent: "agents/postgres", text: "You'll accumulate dead tuples..."},
#   %{agent: "agents/skeptic", text: "The bigger problem is transaction ID wraparound..."},
#   %{agent: "agents/pragmatist", text: "In practice, most teams don't notice for..."}
# ]

result.transcript_id
# => "chat/consult-4973528"
```

One call, aggregated answers from everyone who felt qualified to
respond, a saved transcript you can link to later. The room that
hosted the consultation is stopped on the way out.

## When to consult vs. chat

Different shapes for different situations:

**Consult** when you want parallel perspectives on a single
question. No ongoing dialogue — each agent reads the question, each
responds, you read the set. Good for:

- "What's the failure mode if I do X?"
- "How would each of you approach Y?"
- "Sanity check this plan — anyone see a gap?"

**Chat (live room)** when the conversation is going to have back and
forth. You'll ask follow-ups, agents will reference each other,
someone might need to hand off at context limit. Good for:

- Design discussions
- Code review sessions
- Anything where "let me think out loud" is part of the work

Consult is a single call; chat is a session. The underlying
machinery is the same — consult is chat with the session hidden.

## API

```elixir
Egghead.consult(question, opts \\ [])
```

Options:

| Option          | Default    | What it does                              |
|-----------------|------------|-------------------------------------------|
| `:timeout`      | `120_000`  | Milliseconds to wait before giving up     |
| `:round_budget` | `10`       | Max agent turns; the room's turn budget   |

Return shape:

```elixir
{:ok, %{
  responses: [%{agent: id, text: text}, ...],
  room_id: "consult-<unique>",
  transcript_id: "chat/consult-<unique>" | nil
}}
```

Or `{:error, reason}` if the ephemeral room couldn't be created.

`transcript_id` is `nil` only if the save step failed — the
responses are still returned; you don't lose them because the
filesystem had a bad moment.

## The MCP tool

The same capability over MCP:

```json
{
  "name": "egghead_consult",
  "arguments": {
    "question": "What's the failure mode if we drop autovacuum?",
    "timeout": 120
  }
}
```

Timeout is in **seconds** here (the MCP surface rounds to human
units, not milliseconds). Returns markdown-formatted aggregated
responses with a footer naming the saved transcript:

```markdown
**agents/postgres**

You'll accumulate dead tuples and the table will slowly grow
in size without actually holding more data...

---

**agents/skeptic**

The bigger problem is transaction ID wraparound. Without vacuum,
eventually...

---

_Transcript saved: chat/consult-4973528_
```

This is the single most useful MCP tool for external clients that
want multi-agent input without thinking about rooms. Editor
integrations, CLI scripts, "ask the team" hotkeys — consult is
what they want.

## What happens under the hood

Consultation is a three-step dance:

1. **An ephemeral room is created** with a unique id
   (`consult-<N>`), the requested round budget, and an idle
   timeout so it doesn't linger if something goes wrong.
2. **Your question is sent as an open message.** Every eligible
   agent in the roster gets the same relevance gate they'd get in a
   normal room. Agents that match speak; agents that don't, don't.
3. **Responses are collected** for the requested timeout, the
   transcript is saved as a `class: transcript` record, and the
   room is stopped.

The invisible parts are that the room is real (for those 120
seconds), the addressing logic is the same as any other open
message, and `/pass` is honored (agents who have nothing to add
stay silent rather than fabricate something).

See the [Chat rooms guide]({{< ref "chat-rooms" >}}) for the
addressing model consultation inherits, and the
[Record classes guide]({{< ref "record-classes" >}}) for what the
saved transcript record looks like.
[`egghead eval`]({{< ref "eval" >}}) uses the same
ephemeral-room pattern with a grader attached — consult plus a
judge plus a task definition.

## Turn budget in consult

The default round budget is 10, which is more than you usually
need. Most consultations get one response per agent and stop — but
if an agent responds by @-mentioning another agent ("I'd defer to
@postgres on the wraparound question"), the mentioned agent can
chain in, and that's what the budget allows.

If you want strict one-round-each behavior, set `round_budget: 1`.
If you want a longer back-and-forth among the agents without your
involvement, bump it to 20. The budget trades off latency for
depth.

## What you get back

`responses` is a list of `%{agent: id, text: text}` tuples in the
order the agents replied. Agents that `/pass`-ed don't appear —
you only get substantive contributions.

The `transcript_id` points to a record in your store — persistent,
searchable, linkable. Reference it in a durable note ("See [[chat/
consult-4973528]] for the team's take on autovacuum") and you've
captured the deliberation without having to transcribe anything.

## Degraded mode

If no LLM provider is configured, `Egghead.consult/2` returns
`{:error, :no_providers}`. The `egghead_consult` MCP tool returns a
similar error with a hint about setting an API key. This is the one
feature that *can't* fall back gracefully — there's no such thing as
a one-shot multi-agent answer without agents, and there are no
agents without at least one configured LLM.

See the [Configuration guide]({{< ref "configuration" >}}) for
setting up providers.

## When not to consult

Two anti-patterns worth flagging:

- **As a replacement for a single agent prompt.** If you only want
  one agent's answer, use `Egghead.prompt/3`. Consult spins up a
  room and waits for the whole roster to decide whether to chime in;
  `prompt` goes straight to the named agent. Latency and cost
  difference is real.
- **For tasks that need iteration.** If the question will have
  follow-ups, create a room. Consult saves a transcript, but
  resuming it means `/join chat/consult-<N>` — at which point you
  probably wanted a room from the start.

Otherwise: consult is a good default. Ask, receive, file it away,
move on.
