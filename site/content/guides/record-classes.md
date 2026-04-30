---
title: Record classes
section: Records
weight: 12
summary: The six classes — durable, inbox, deliberation, transcript, agent, skill — and what each one means in practice.
---

The `class:` field in a record's frontmatter tells the rest of
the system how to treat that record. Six values are recognized,
and the default — when you omit `class:` entirely — is
`durable`. Unknown values are silently treated as `durable`
too, so a typo like `class: durabel` will not produce an error;
your record loads as a regular note.

| Class          | Written by | Behavioral effect |
|----------------|------------|-------------------|
| `durable`      | you        | The default. No special handling. |
| `inbox`        | you, often agents | An organizational label. Appears as a filter in the web UI alongside other classes; otherwise behaves like `durable`. |
| `deliberation` | system     | Written by Egghead during agent handoff or consultation; otherwise treated as a regular record. |
| `transcript`   | system     | Recognized by `/join` for re-hydrating a saved chat into a live room. |
| `agent`        | you        | Loaded by the agent supervisor as a running agent. |
| `skill`        | you        | Indexed as an invocable skill. |

The behavioral column is mostly empty for `durable` and `inbox`
on purpose. Class is primarily a *label* — useful for filtering
in the UI and signaling intent to other agents reading the
store — and most of the system runs the same code regardless of
which value is set. The exceptions are `transcript`, `agent`,
and `skill`, where the class actually changes how Egghead loads
the record.

A few things `class:` is *not*, before we go further. It is not
a permission boundary; capability checks operate on resource and
verb (see [Capabilities]({{< ref "capabilities" >}})), not on
class. It is not a directory; a record's class is independent of
where the file sits on disk. And it is not a schema; an agent
record missing a `model:` line still loads, with the default
filled in.

## `durable`

The default. Use this for permanent notes, design documents,
references, or anything else you want indexable and editable
indefinitely. If you omit `class:` entirely, you get `durable`
without having to write it.

```yaml
---
id: notes/how-rebases-work
class: durable
tags: [git, reference]
---
```

## `inbox`

Use `inbox` for short-lived capture: scraped pages, quick notes
you want to look at again before deciding whether they matter,
working artifacts an agent created during a tool call. Nothing
in the system automatically prunes inbox records. The class is
a label that signals "not load-bearing" to both you and any
agent reading the store; promote a record to `durable` by
editing the frontmatter, and delete one with `rm`.

```yaml
---
id: inbox/2026-04-19-standup-notes
class: inbox
---
```

## `deliberation`

Egghead writes deliberation records itself: when an agent hands
off because its context window is filling up, the agent
summarizes its session into a deliberation, and when a
[consultation room]({{< ref "consultation" >}}) produces a
result, the room's reasoning is saved as a deliberation too.
Treat these as read-mostly. The value of having them in the
store is that the reasoning is indexed, linkable, and
reviewable later.

```yaml
---
id: deliberations/2026-04-19-refactor-planning
class: deliberation
tags: [deliberation, room:design-chat]
links: [agents/scout, agents/archivist]
---
```

## `transcript`

A transcript is the saved log of a [chat
room]({{< ref "chat-rooms" >}}), produced by
`Egghead.chat_save/1` or by typing `/save` in the TUI. Each
message is rendered with a `**name** at <timestamp>` header
followed by the body verbatim. The participants of the room
are captured in `links:`.

```yaml
---
id: chat/architecture-sync
class: transcript
tags: [transcript]
links: [agents/scout, agents/index]
---
```

If you later run `/join chat/architecture-sync`, Egghead reads
the transcript back and rehydrates a live room from it, picking
up where you left off. That is the difference between a
transcript and a deliberation: transcripts can come back to
life, deliberations cannot.

## `agent`

An agent record defines an agent. The frontmatter carries the
agent's identity, its model choice, and its capabilities; the
body of the record is the system prompt the agent runs under.

```yaml
---
id: agents/scout
class: agent
model: anthropic/claude-sonnet-4-6
capabilities:
  - records.read
  - records.create
---

# Scout

You are Scout. ...
```

Editing the file hot-reloads the running agent — the next
message addressed to the agent uses the updated configuration —
and deleting the file stops the process. The full surface,
including the `quiet:` and `idle:` properties that change how
the coordinator and the room treat the agent, lives in
[Agents]({{< ref "agents" >}}).

## `skill`

A skill record declares a task that an agent can invoke,
together with the tools the task needs and the instructions for
performing it. Agents that hold the capabilities a skill
declares can invoke that skill; agents that don't simply never
see it.

```yaml
---
id: skills/pr-review
class: skill
name: pr-review
description: Review a GitHub pull request for obvious issues.
allowed-tools: Bash(gh:*) Read Grep
---
```

The full skill format and the way capability checks work for
skill invocation are documented in
[Skills]({{< ref "skills" >}}).
