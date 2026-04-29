---
title: Consultation
section: Integrations
weight: 32
summary: One-shot multi-agent question. Spins an ephemeral room, collects responses, saves the transcript, stops the room.
---

`Egghead.consult/2` and the `egghead_consult` MCP tool give you
a single-call shape for multi-agent input: you ask one
question, Egghead creates a temporary chat room, sends the
question as an open message, collects responses up to a
timeout, saves the transcript, and stops the room. The result
is a list of `{agent, text}` pairs and a record id you can
link to.

Use consultation when you want parallel takes on a single
question without managing a room yourself. The room is gone by
the time the call returns; what's left is the transcript on
disk.

## When to use a consult versus a chat room

Consultation is the right shape when each agent reads the
question, the relevant ones respond, and the result is a set
of independent perspectives.

A live chat room is the right shape when the conversation is
going to have follow-ups, when agents need to reference each
other's work across multiple turns, or when the session might
run long enough to need handoffs.

Consult is one call; a chat room is a session. Under the hood,
consult is a chat room with the lifecycle hidden.

## Elixir API

```elixir
Egghead.consult(question, opts \\ [])
```

| Option          | Default   | Purpose |
|-----------------|-----------|---------|
| `:timeout`      | `120_000` | Milliseconds to wait before the room is force-stopped. |
| `:round_budget` | `10`      | Maximum agent turns. |

Returns:

```elixir
{:ok, %{
  responses: [%{agent: id, text: text}, ...],
  room_id: "consult-<unique>",
  transcript_id: "chat/consult-<unique>" | nil
}}
```

`transcript_id` is `nil` only if the save step itself failed;
the responses are still returned, so you do not lose them
because the filesystem had a bad moment.

If no LLM provider is configured, the call returns
`{:error, :no_providers}`.

A short example:

```elixir
{:ok, result} = Egghead.consult(
  "What's the failure mode if we disable autovacuum?")

for %{agent: id, text: text} <- result.responses do
  IO.puts("#{id}: #{text}")
end
```

## MCP tool

The same shape over MCP:

```json
{
  "name": "egghead_consult",
  "arguments": {
    "question": "What's the failure mode if we disable autovacuum?",
    "timeout": 120
  }
}
```

The MCP tool's `timeout` is in seconds rather than
milliseconds. The response comes back as a Markdown-formatted
block with each agent's reply separated by a horizontal rule
and the saved transcript id at the bottom:

```markdown
**agents/postgres**

You'll accumulate dead tuples...

---

**agents/skeptic**

The bigger issue is transaction ID wraparound...

---

_Transcript saved: chat/consult-4973528_
```

This is the most useful tool for an external client that wants
multi-agent input but does not want to think about rooms,
budgets, or transcripts. Editor integrations, CLI scripts, and
"ask the team" hotkeys all tend to land here.

## What happens internally

Each consultation runs through four steps. Egghead creates a
chat room with a unique id (`consult-<N>`), the requested
round budget, and an idle timeout that protects against a
hang. It sends the question as an open message, which means
the activation gate runs the same TF-IDF relevance scoring it
runs in any other open message; agents whose tags or
disposition score above threshold respond. It collects
responses until the budget runs out or the timeout expires.
Then it saves the transcript as a `class: transcript` record
with id `chat/consult-<N>` and stops the room.

`/pass` is honored. Agents that have nothing useful to add
stay silent rather than fabricate a reply, and silent agents
do not appear in `responses`.

`@everyone` and `@jam` modes are not exposed by consultation.
Use a live chat room if you need them.

## Round budget

The default round budget of 10 is more than most consultations
need. Most produce one response per relevant agent and stop.
The budget exists to allow short follow-up chains: an agent
that responds by `@`-mentioning another ("defer to @postgres
on that") triggers the mentioned agent's reply, which costs a
turn from the budget.

Set `round_budget: 1` if you want a strict one-round-each
behavior. Set it higher if you want the agents to discuss
amongst themselves a bit before the room shuts down.

## Linking to a saved consultation

The `transcript_id` points at a record in your store, so
referencing the consult from a durable note is just a wikilink:

```markdown
See [[chat/consult-4973528]] for the team's take on autovacuum.
```

If you decide later that the consultation should keep going,
`/join chat/consult-<N>` rehydrates the transcript into a live
room — but at that point a chat room from the start would have
been the simpler choice.

## See also

- [Chat rooms]({{< ref "chat-rooms" >}}) covers the addressing
  model and the activation gate that consultation inherits.
- [MCP server]({{< ref "mcp" >}}) covers the
  `egghead_consult` tool surface for external clients.
- [Evals]({{< ref "eval" >}}) is the same ephemeral-room shape
  with a Judge attached and a milestone-based scoring step.
