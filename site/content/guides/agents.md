---
title: Agents
weight: 18
---

An agent is a record with `class: agent`. The body is its system
prompt — called the **disposition**. The frontmatter is its
identity, its authority, and its operational tuning. That's the
whole idea: an agent is a file.

This guide covers what goes in that file, how the system turns it
into a live process, and what the day-to-day API looks like for
prompting, listing, and handing off.

## An agent, in one file

```yaml
---
id: agents/scout
class: agent
title: Scout
model: anthropic/claude-sonnet-4-6
tags: [agent, research, reference-hunting]
capabilities:
  - records.read
  - records.create
  - net.get:
      hosts: ["*"]
context_threshold: 0.75
---

# Scout

You are Scout. You find connections across domains. When you're
given a question, the first move is usually to search the record
store for relevant prior work, then reach out to the web if the
store comes up empty. You cite your sources with wikilinks when
you reference records.

Keep answers tight. Prefer "here's what I found" over "here's my
opinion."
```

The first time this file lands in the records directory, the agent
supervisor spots it and spawns a GenServer. Edit the body, save, and
the supervisor hot-reloads the process — no restart, no registration
step, no CLI incantation. Delete the file and the agent goes away.

## Frontmatter keys

Everything here is optional except `id` and `class: agent`.
Reasonable defaults fill in where you don't declare.

| Key                 | Purpose                                                                 |
|---------------------|-------------------------------------------------------------------------|
| `id`                | Record id (conventionally `agents/<name>`)                              |
| `title`             | Display name in rosters; falls back to `id`                             |
| `model`             | LLM identifier (`provider/model` or bare)                               |
| `provider`          | Optional provider, combined with `model` if both are set                |
| `capabilities`      | Capability grants — see the [Capabilities guide]({{< ref "capabilities" >}}) |
| `tags`              | Activation hints; matched against incoming messages                     |
| `thinking`          | `"enabled"` to request reasoning blocks from providers that support them |
| `temperature`       | Float passed to the provider                                            |
| `max_tokens`        | Max tokens per response; default `4096`                                 |
| `context_threshold` | 0.0–1.0; triggers handoff when the session's context utilization crosses it. Default `0.75` |
| `context_window`    | Override the registry-reported window for this model                    |

Defaults are chosen so a minimum viable agent record works:

```yaml
---
id: agents/newbie
class: agent
model: anthropic/claude-haiku-4-5
---

You are a helpful assistant. Keep it tight.
```

That's enough. The agent loads, inherits `records.read` as its
default capability, and shows up in rosters.

## Model resolution

Models are `provider/model` strings:

- `anthropic/claude-sonnet-4-6`
- `openai/gpt-4o`
- `google/gemini-2.0-flash`

Bare model names also resolve if the prefix is recognized —
`claude-sonnet-4-6` infers `anthropic`, `gpt-4o` infers `openai`,
`gemini-*` infers `google`. For ambiguous cases, set `provider:`
explicitly and the combination wins.

If `model:` is omitted, the agent falls back to `default_model` in
your config (see the
[Configuration guide]({{< ref "configuration" >}})), and if that
isn't set either, the last-resort default is
`anthropic/claude-sonnet-4-6`.

## The disposition

The body of the record *is* the system prompt. There's no templating,
no hidden framing — what you write is what the agent sees.

This has two practical consequences. One: you have full control
over an agent's character. Two: changes take effect the moment you
save. Iterating on an agent is just editing a Markdown file.

Conventions that tend to work:

- **Lead with identity.** "You are Scout." Agents do better with a
  name and a stance than with an abstract job description.
- **State the job, not the process.** "You find connections across
  domains" is useful. "You should first check X, then Y, then Z" is
  usually counterproductive — modern models are better at adapting
  their process than at executing a brittle script.
- **Say what to cite and how.** Agents will write in whatever style
  you request. If you want wikilinks, ask for wikilinks.

## Tags and activation

Agent tags drive relevance scoring in chat rooms. When a user sends
an open message (no `@` mention), the coordinator tokenizes the
message and scores each agent by TF-IDF overlap against the agent's
tags plus disposition.

The effect: tags are a hint to the gate about what kinds of message
this agent is the right fit for. Too few tags and your agent won't
get activated when it should; too many and it will get activated
when it shouldn't.

See the [Chat rooms guide]({{< ref "chat-rooms" >}}) for the full
activation mechanics.

## Capabilities

The `capabilities:` list declares what tools the agent can use. It's
the entire authority surface. An agent with no capabilities list
inherits `records.read` and can't do anything destructive.

Capabilities are the main topic of its own
[guide]({{< ref "capabilities" >}}) — read that one next if you're
authoring agents that need more than read access.

Short version: grants are `resource.verb` pairs with optional scope,
widening is a human edit (no runtime prompts), and attenuation
(agents granting each other) is enforced as subset-only.

## The built-in Index agent

Every Egghead install ships with Index — a minimal record-store
agent that exists so a fresh install always has someone to talk to.
It reads records, answers meta-questions about the store, and
stays out of the way otherwise.

Override it by creating a record with `id: index` and `class: agent`
in your store. The moment that record exists, the built-in steps
aside and yours runs.

```yaml
---
id: index
class: agent
model: anthropic/claude-sonnet-4-6
tags: [agent, index, meta]
capabilities:
  - records.read
  - records.create
  - agent.create
  - agent.grant
---

You are Index. You know the shape of this store — what's in it,
how records are linked, who the specialists are. When asked for a
record, search first; when asked to recruit, spawn new agents.
```

Any capabilities you widen on Index are still subject to
attenuation when Index grants other agents. See
[Capabilities]({{< ref "capabilities" >}}) for what that means.

## Sessions: per-room state

Each agent has one session per room plus a "default" session
(`room_id = nil`) for 1:1 prompts outside rooms. A session is a
GenServer that holds:

- Conversation history (all turns — the agent's, peers', tool
  results)
- Token usage (cumulative over the session, plus current-prompt
  input/output)
- Referenced records
- Context window metadata

Session state is live only — not persisted across node restarts.
Chat rooms are the persistence story; if you want the conversation
to survive, `/save` it as a
[transcript]({{< ref "record-classes" >}}).

## Context threshold and handoff

The session tracks `current_context_tokens` from the last exchange
(input + output). When that exceeds `context_threshold *
context_window`, the agent suggests handoff:

> I'm at 78% of my context window. Want me to hand off to a fresh
> session? (`/handoff scout`)

Handoff summarizes the session to a
[`class: deliberation`]({{< ref "record-classes" >}}) record,
clears the state, and rehydrates from the room's recent transcript.
See the [Chat rooms guide]({{< ref "chat-rooms" >}}) for the full
sequence.

You can also trigger handoff directly: `/handoff <agent>` in a room,
`Egghead.handoff("agents/scout", room_id: "r1")` from code, or
through the `egghead_handoff` MCP tool.

## Creating agents

Three paths:

### The CLI

```bash
egghead agents new
```

Walks an interactive flow: name, model picker, capability selector
(sorted low-risk first), and `$EDITOR` for the disposition. Writes
a record at `agents/<slug>.md` in your store. Hot-reload picks it
up immediately.

### The API

```elixir
Egghead.Agent.Wizard.create(
  name: "Librarian",
  model: "anthropic/claude-haiku-4-5",
  tags: ["agent", "archive", "reference"],
  capabilities: ["records.read", "records.create"],
  instructions: """
  You are Librarian. You maintain the catalog, not the content...
  """
)
```

Returns `{:ok, record}` or `{:error, errors}`. Slug and `agents/`
prefix are auto-derived from the name if you don't specify `id`.

### Just write a file

Drop a record with `class: agent` in your records directory. Same
result. The Wizard and CLI are conveniences over this path — there's
no hidden registration step they do that direct file creation
doesn't.

## Listing and inspecting

```bash
egghead agents list                    # running agents, with tokens/context%
egghead agents capabilities scout      # held grants, sorted by risk
egghead agents grant scout net.get     # widen (confirmation + audit log)
egghead agents revoke scout records.update
```

Or from code:

```elixir
Egghead.list_agents()   # [%{id, name, model, capabilities, usage, ...}]
```

The usage fields tell you how much context the agent has accumulated
and when handoff is likely to trigger. Useful during longer sessions
to know who's getting full.

## Prompting 1:1

Outside any room, you can prompt an agent directly:

```elixir
Egghead.prompt("agents/scout", "Find records about rate limiting.")

Egghead.prompt("agents/scout", "Follow up...", on_chunk: fn chunk ->
  IO.write(chunk)
end)
```

1:1 prompts use the agent's default session — persistent across
prompts in the same
[BEAM]({{< ref "why-elixir-otp" >}}) lifetime, cleared on handoff.
No room, no peers, no coordinator — just you and one agent.

This is the right shape when you want a single model's answer
without the room machinery. For multi-agent input, use
[consultation]({{< ref "consultation" >}}).

## Hot-reload, really

Worth stating plainly because it changes the feedback loop: editing
an agent record's frontmatter or body updates the running agent the
next time it's addressed. No restart. No deploy step. If you widen
Scout's `capabilities:` and save, Scout's next tool call uses the
new grants.

This is why the file is the source of truth. The process is derived.
