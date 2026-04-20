---
title: Record classes
weight: 12
---

Most records you write are notes, and most notes are the same
lifecycle: durable until you retire them. The `class:` field on a
record's frontmatter lets you mark the ones that behave differently —
temporary inboxes, append-only audit trails, live agent definitions —
so the rest of the system knows how to treat them.

Six classes exist. Three are for human-written content, three are
for system artifacts that happen to live in the same store.

## `durable` — the default

A permanent knowledge record. Long-lived, linkable, searchable,
editable, deletable when you decide it's no longer useful. Every note
you write is durable unless you say otherwise.

```yaml
---
id: notes/how-rebases-work
class: durable
tags: [git, reference]
---
```

Omit the `class:` line entirely and you get `durable` anyway — this
is the one you reach for without thinking. Use it for notes,
references, design documents, meeting summaries, field guides,
personal memos, anything you'd want to look at again in six months.

## `inbox` — ephemeral capture

Short-lived artifacts with no expectation of permanence. Scraped
pages, email summaries, "let me jot this down before I forget" notes,
context gathered by an agent on your behalf.

```yaml
---
id: inbox/2026-04-19-standup-notes
class: inbox
tags: [inbox, meeting]
---
```

An inbox record is just a record — nothing automatic prunes them.
What the class buys you is social signaling: you and your agents both
know these aren't load-bearing. Promote one to `durable` when you
decide it earned permanence; delete it when you don't.

Agents often create inbox records during tool use (saving a fetched
page, stashing an interim finding). Search results from an agent's
session can safely land here without cluttering your durable notes.

## `deliberation` — append-only audit

A record of an agent thinking through something. Written by the
system, not by you.

```yaml
---
id: deliberations/2026-04-19-refactor-planning
class: deliberation
tags: [deliberation, room:design-chat]
links: [agents/scout, agents/archivist]
---
```

When an agent's context gets full and the system hands off (see the
[Chat rooms guide]({{< ref "chat-rooms" >}}) for handoff), the
agent's accumulated reasoning is summarized into a deliberation
record. When you ask an ephemeral room a question via
[consultation]({{< ref "consultation" >}}), the resulting transcript
is saved as a deliberation.

Treat deliberations as read-mostly. The value is in having them in the
graph — searchable, linkable, reviewable — not in revising them
after the fact. If you disagree with something a deliberation
captures, write a durable record that says so and link both.

## `transcript` — saved chat

The full log of a live chat room, serialized as a record when the
room is saved.

```yaml
---
id: chat/architecture-sync
class: transcript
tags: [transcript]
links: [agents/scout, agents/archivist, agents/index]
---

**mark** at 2026-04-19 14:03

Okay, let's talk through the auth rewrite...
```

Calling `Egghead.chat_save/1` or typing `/save` in the TUI produces
one. The record id follows a `chat/<room>` convention; participants
of the room are captured in `links`; the body renders each message
with a header and the content verbatim.

Saved transcripts are rehydratable. `/join <room>` in the TUI against
a transcript record spins a live room back up from the saved state —
the conversation continues from where you left off. This is why
transcripts are a distinct class from deliberations: deliberations
are closed artifacts; transcripts are potentially still alive.

## `agent` — a participant in the store

An agent record describes an AI agent that can speak in rooms,
execute tools, and write records. The body is the agent's system
prompt; the frontmatter configures which model it uses, what tools it
can reach for, and what it's good at.

```yaml
---
id: agents/scout
class: agent
model: anthropic/claude-sonnet-4-6
tags: [agent, research]
capabilities:
  - records.read
  - records.create
  - net.get:
      hosts: ["*"]
---

# Scout

You are Scout. You find connections across domains...
```

Edit an agent's record, save, and the supervisor hot-reloads the
process — no restart, no CLI incantation. Delete the record and the
agent goes away. The file is the source of truth.

See the [Agents guide]({{< ref "agents" >}}) for the full frontmatter
surface and the
[Capabilities guide]({{< ref "capabilities" >}}) for how
`capabilities:` governs what an agent is allowed to do.

## `skill` — reusable instruction set

A skill is a packaged way of doing something — instructions for a
common task, plus the tool dependencies the task needs. Skills live
in the same store as everything else, or in a separate drop-zone
directory (default `~/.agents/skills/`) for portability.

```yaml
---
id: skills/pr-review
class: skill
name: pr-review
description: Review a GitHub pull request for obvious issues.
allowed-tools: Bash(gh:*) Read Grep
---

# PR review skill

When asked to review a PR, fetch the diff with `gh pr diff`, then...
```

Any agent with the capability surface a skill requires can invoke it;
skills never widen capabilities — your agent's grants are the gate.
See the [Skills guide]({{< ref "skills" >}}) for authoring and
discovery, and the
[Capabilities guide]({{< ref "capabilities" >}}) for how the
capability check happens.

## Choosing a class

Most of the time, you don't. The default is `durable` and it's
almost always right. The system-written classes (`deliberation`,
`transcript`) get set automatically by the features that produce
them. The configuration classes (`agent`, `skill`) are obvious when
you're authoring one.

`inbox` is the one worth remembering. It's the release valve when
you want to capture something quickly without feeling like you're
promising to maintain it.

## What `class:` does not do

- **It's not a permission boundary.** Any class of record is subject
  to the same [capability checks]({{< ref "capabilities" >}}).
  The distinction between `records.*` and `agent.*` grants is about
  target, not about class.
- **It's not a directory.** You can store records anywhere inside
  your records directory; the `class:` field and the file path are
  independent. A conventional layout (`agents/` for agents,
  `skills/*/SKILL.md` for skills, `inbox/` for inbox) is helpful for
  humans but not required by the parser.
- **It's not a schema.** The class doesn't validate frontmatter.
  An agent record with no `model:` key won't be rejected — the
  defaults fill in, and the record loads. See each feature guide
  for what a given class typically carries.
