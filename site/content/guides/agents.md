---
title: Agents
section: Agents
weight: 18
summary: An agent is a Markdown record with class agent. Frontmatter declares model and capabilities; the body is the system prompt.
---

An agent is a record with `class: agent`. The body of the
record is the agent's system prompt. The frontmatter declares
the agent's identity, the model it uses, and the capabilities
it holds.

When a record with `class: agent` appears in the records
directory — or when one already there is edited — Egghead
starts an agent process for it, or hot-reloads the existing
process if there is one. Deleting the record stops the process.
There is no separate registration step, no decorator to add to
a Python class, no role definition in a separate YAML file. The
file is the agent.

That is one of the larger design differences from the
frameworks the typical Egghead user has tried. In CrewAI an
agent is a Python object you instantiate; in Paperclip it is a
configuration entry against the dashboard's schema. Either
shape works, but it ties the agent's lifetime to a build step.
Egghead skips the build step: editing the file is the deploy.

## Minimal example

```yaml
---
id: agents/scout
class: agent
model: anthropic/claude-sonnet-4-6
tags: [research]
capabilities:
  - records.read
  - records.create
  - net.get:
      hosts: ["*"]
---

# Scout

You are Scout. You find connections across domains. Search the
records first; reach out to the web only if local results are
empty. Cite sources with wikilinks.
```

## Frontmatter keys

The only required key is `class: agent`. The id is derived
from the file's path inside the records directory (with the
extension stripped), so a record at `agents/researcher.md` has
the id `agents/researcher` whether or not you write `id:` in
the frontmatter. Everything else has a sensible default.

| Key                 | Type        | Default | Purpose |
|---------------------|-------------|---------|---------|
| `id`                | string      | derived from path | Stable identifier. Override only if you want it to differ from the filename. |
| `title`             | string      | id      | Display name in rosters and `/whois`. |
| `model`             | string      | config `default_model` | LLM identifier in `provider/model` form. |
| `provider`          | string      | inferred | Combined with `model:` if `model:` is bare. |
| `capabilities`      | list        | `[records.read]` | Capability grants. See [Capabilities]({{< ref "capabilities" >}}). |
| `access`            | `r`/`w`/`rw`| —       | Shorthand for the common record-bundle grants. Documented in [Capabilities]({{< ref "capabilities" >}}). |
| `tags`              | list        | `[]`    | Free-form. The activation gate uses these for relevance scoring. |
| `thinking`          | `enabled`/`disabled` | disabled | Request reasoning blocks from providers that support them. |
| `temperature`       | float       | provider default | Passed through to the provider. |
| `max_tokens`        | int         | 4096    | Cap on output tokens per response. |
| `context_threshold` | float (0..1)| 0.70    | Triggers a handoff suggestion when session usage exceeds this fraction of the model's window. |
| `context_window`    | int         | registry value | Override the registry-reported window. |
| `disposition`       | string      | body    | Optional override; defaults to the record body. |

The minimum viable agent is one frontmatter line plus a body.
Save this file as `agents/newbie.md`:

```yaml
---
class: agent
---

You are a helpful assistant.
```

That record loads as a working agent. The id (`agents/newbie`)
is taken from the filename, the model is taken from
`default_model` in `config.yml`, and the capability set is
`[records.read]` — every agent can read and search the records
store by default, which is enough to be useful in a room
without being able to do any harm.

If you want broader authority, that lives in `capabilities:`,
which is the entire authority surface for the agent. The full
syntax, the catalog of resources and verbs, the `access:`
shorthand for the common cases, and the OS sandbox for
filesystem and process verbs are documented in
[Capabilities]({{< ref "capabilities" >}}).

## Model resolution

Models are written as `provider/model`:

- `anthropic/claude-sonnet-4-6`
- `openai/gpt-4o`
- `google/gemini-2.0-flash`

A bare model name resolves where the prefix is unambiguous:
`claude-*` infers `anthropic`, `gpt-*` infers `openai`,
`gemini-*` infers `google`. For ambiguous cases, set
`provider:` explicitly, and the combination wins.

If `model:` is omitted entirely, the agent uses
`default_model` from `config.yml`, and if neither is set, the
fallback is `anthropic/claude-sonnet-4-6`.

## Tags and activation

Tags are matched against incoming messages by the coordinator's
relevance scoring. The coordinator tokenizes each open message
and computes a
[TF-IDF](https://en.wikipedia.org/wiki/Tf%E2%80%93idf) overlap
between those tokens and each agent's tags plus disposition;
the highest-scoring agent responds first. The full activation
logic is in [Chat rooms]({{< ref "chat-rooms" >}}).

The practical implication is that tags are a hint about which
kinds of message this agent is the right responder for. Too few
tags and the agent gets skipped on relevant messages; too many
and the agent gets activated on messages that aren't really for
it.

## The disposition

The body of the record is the system prompt, with no templating
and no hidden framing. What you write is what the model sees on
every turn. Editing the body and saving is enough to update the
running agent — the next turn uses the new prompt.

That has two practical consequences. Iterating on an agent
feels like editing a document, because that is what it is. And
the agent's identity lives in a file you can grep, diff, and
review.

## Capabilities

The `capabilities:` list (and the `access:` shorthand) is the
agent's entire authority surface. An agent record with neither
key set inherits `[records.read]` — enough to read and search
the store but nothing else.

Grants are written as `resource.verb` strings, optionally with
a scope:

```yaml
capabilities:
  - records.read
  - records.create:
      classes: [inbox, deliberation]
  - net.get:
      hosts: ["docs.python.org", "*.wikipedia.org"]
```

The full grammar, the catalog of resources and verbs, the
scope keys for each verb, the attenuation rules for one agent
granting another, and the OS sandbox for filesystem and process
verbs are all documented in
[Capabilities]({{< ref "capabilities" >}}). Read that guide
before you author an agent that does anything beyond reading
records.

## The built-in `index` agent

Every Egghead install ships with a built-in agent named
`index`. It holds `[records.read]` and exists so a fresh
install always has someone to talk to. The built-in is
process-only; there is no record for it in your store.

To customize, write a record with `id: index` and
`class: agent`. As soon as that record exists, the built-in
steps aside and yours runs in its place.

## Sessions

Each agent has one session per room (keyed by room id) plus a
default session (`room_id = nil`) used by `Egghead.prompt/3`
calls outside any room. The session is where the agent's
working memory for that room lives: the conversation history
the agent has seen, the cumulative token usage and the most
recent input/output counts, the records the agent has
referenced, and the model's context-window metadata.

Session state is in-memory only. Persistence is the room's
job: `/save` writes the room's transcript as a record;
`/handoff` writes a deliberation and clears the session.
Restarting the node loses every active session, but agents
rehydrate from saved transcripts the next time they are
re-invited into a room.

## Context threshold

The session tracks the most recent exchange's input + output
tokens against the model's context window. When that ratio
exceeds `context_threshold` (default 0.70), the agent emits a
suggestion in chat:

> I'm at 78% of my context window. Want me to hand off?
> (`/handoff <name>`)

You can trigger the handoff with `/handoff <agent>` in the
room, with `Egghead.handoff/2` from code, or with the
`egghead_handoff` tool over MCP.

## Creating agents

There are three paths, and they all produce the same record
on disk.

### Interactive CLI

```bash
egghead agents new
```

The wizard asks for a name, a model, a capability set
(sorted from low risk to high), and a disposition (it opens
`$EDITOR` for you), then writes `agents/<slug>.md` in your
records directory.

### Programmatic

```elixir
Egghead.Agent.Wizard.create(
  name: "Librarian",
  model: "anthropic/claude-haiku-4-5",
  tags: ["archive", "reference"],
  capabilities: ["records.read", "records.create"],
  instructions: """
  You are Librarian. You maintain the catalog.
  """
)
```

Returns `{:ok, record}` or `{:error, errors}`. The `:access`
option works here too, and composes with `:capabilities` the
same way it does in YAML.

### Direct file write

Drop a record with `class: agent` anywhere in the records
directory. Egghead picks it up. The CLI and the wizard are
conveniences over this path; there is no hidden registration
step they perform that direct file creation does not.

## Listing and inspecting

```bash
egghead agents list                    # running agents, with tokens and context%
egghead agents capabilities scout      # held grants, sorted by risk
egghead agents grant scout net.get     # widen, with confirmation
egghead agents revoke scout records.update
```

```elixir
Egghead.list_agents()  # [%{id, name, model, capabilities, usage, ...}]
```

Inside a room, `/whois <agent>` is the conversational form: it
prints model, capabilities, joined rooms, and a wikilink to
the source record.

## Prompting outside a room

```elixir
Egghead.prompt("agents/scout", "Find records about rate limiting.")
```

With streaming:

```elixir
Egghead.prompt("agents/scout", "Follow up...",
  on_chunk: fn chunk -> IO.write(chunk) end)
```

`prompt/3` uses the agent's default session. There is no
coordinator, no peers, and no turn budget — just one prompt and
one response. Use it when you want a single agent's answer
without spinning up a room. For multi-agent input, use
[Consultation]({{< ref "consultation" >}}).

## Hot-reload, in practice

It's worth stating plainly because it changes the development
loop: editing an agent record's frontmatter or body and saving
the file is the entire deployment step. The next message
addressed to the agent uses the new configuration. Widen
`capabilities:` and save; the next tool call uses the new
grants. Swap the model and save; the next response is from the
new model.

This is why the file is the source of truth and the process is
derived. You iterate on agents the way you iterate on Markdown
notes: with an editor.
