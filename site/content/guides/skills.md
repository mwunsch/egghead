---
title: Skills
section: Agents
weight: 19
summary: Reusable instruction sets with declared tool requirements. Agents that already hold the required capabilities can invoke them.
---

A skill is a Markdown file that pairs an instruction body with a
declaration of the tools that body assumes. An agent invokes a
skill when the user asks it to perform the task the skill
describes; the skill itself contains no executable code.

Egghead's skill format follows the [Agent Skills
spec](https://agentskills.io/home), which is the same format
Claude Code and a growing number of other agent harnesses
already use. If you have skills written for one of those tools
already, dropping them into your Egghead skills directory is
typically all it takes to make them work; the frontmatter keys
and the `allowed-tools` syntax are the same. The one place
Egghead diverges from the rest of the ecosystem is in how the
`allowed-tools` declaration is interpreted at invocation time.

Skills do not grant capabilities. If a skill declares
`allowed-tools: WebFetch`, that is a *requirement* the agent
must already meet, not a *grant* that suddenly gives the agent
web access. This is a deliberate departure from frameworks like
CrewAI, where adding a tool to an agent's spec is what unlocks
it. In Egghead, an operator-supplied capability list is the
gate, and a skill that needs a tool the agent cannot use simply
never appears in that agent's discovery list.

## Where Egghead looks for skills

There are three sources, and Egghead unifies them in one
listing:

1. The drop-zone directory, which defaults to
   `~/.agents/skills/`. Override by setting `skills_dir` in
   `config.yml`. Each subdirectory containing a `SKILL.md` is
   one skill.
2. Anywhere in your records directory, by class — any record
   whose frontmatter has `class: skill` is loaded as a skill.
3. By convention inside the records directory — any file at
   `skills/<name>/SKILL.md` is auto-promoted to `class: skill`,
   so you do not have to write the line.

`egghead skills list` shows every skill from every source. There
is no behavioral difference between the three paths; the choice
is about portability. Drop-zone skills follow you across nodes;
records-directory skills travel with the project they belong to.

## File format

```yaml
---
name: pr-review
description: Review a GitHub pull request for obvious issues.
allowed-tools: Bash(gh:*) Read Grep
compatibility: Best with Claude Sonnet 4+ or equivalent.
---

# PR review

When asked to review a pull request:

1. Fetch the diff with `gh pr diff <number>`.
2. Scan for missing error handling, test coverage gaps, and
   obvious security issues.
3. Cite specific file and line locations.
```

| Key             | Required | Constraint |
|-----------------|----------|------------|
| `name`          | yes      | Lowercase, hyphens, ≤ 64 characters. |
| `description`   | yes      | One line, ≤ 1024 characters. Surfaces in `skills list`. |
| `allowed-tools` | no       | Space-separated tokens. Syntax below. |
| `compatibility` | no       | Free-form note about model fit. Not interpreted by Egghead. |

The body — everything after the frontmatter — is the
instruction set the invoking agent reads. An empty body fails
validation; the prose is the substance of the skill, and the
frontmatter is the index card.

## `allowed-tools` syntax

`allowed-tools` is a space-separated list of tokens in
Claude-Code-compatible syntax. Each token translates to a
capability requirement at invocation time:

| Token                         | Translates to                            |
|-------------------------------|-------------------------------------------|
| `Bash(git:*)`                 | `proc.exec{patterns: ["git:*"]}`          |
| `Bash(rg)`                    | `proc.exec{cmds: ["rg"]}`                 |
| `Read`                        | `fs.read`                                 |
| `Grep`                        | `fs.read`                                 |
| `WebFetch(domain:github.com)` | `net.get{hosts: ["github.com"]}`          |
| `WebSearch`                   | `net.get{hosts: ["*"]}`                   |

Tokens that do not map to a known tool surface as warnings in
`egghead skills check`. They are not errors — a skill is
allowed to reference a tool Egghead has not learned about yet —
but they do flag that the token will not produce a capability
check.

## Why skills cannot widen capabilities

Most agent frameworks treat tool declarations as the place where
authority gets granted. You add `WebFetch` to the agent's tool
list, and now the agent can fetch the web. Egghead splits those
two ideas: capabilities are granted by the operator in the
agent's frontmatter; skills *consume* those capabilities. A
skill is more like a recipe than a permission slip.

The practical effect is that you can install a skill from
someone else's repository without worrying about what authority
it grants. If your agents already have the capabilities the
skill needs, the skill works. If they don't, the skill is
filtered out of discovery for those agents — silently, with no
prompt and no surprise. Curating who has what stays under your
control, per agent, per node.

## CLI

```bash
egghead skills list                       # every available skill, with source
egghead skills show pr-review             # frontmatter + body for one skill
egghead skills check pr-review --agent scout
```

`check` is the command worth knowing during development. For a
given agent it tells you which `allowed-tools` tokens the
agent's capabilities satisfy, which tokens are missing, and the
exact `egghead agents grant` line you would run to fill each
gap. Use it to debug "why doesn't the skill show up for this
agent" before reaching for anything else.

## Authoring guidance

A few patterns that work well in practice.

Be specific in `description`. It is what an agent reads when
deciding whether to invoke the skill. "Review a PR" is too
vague to be useful; "Review a GitHub PR for security issues and
test coverage gaps" gives the model something to match against.

Declare tools narrowly. `Bash(git:*)` is better than `Bash` for
the same reason a narrow capability is better than a broad one:
operators tend to grant exactly what is requested, and a broad
declaration asks for broader authority than the skill actually
needs.

Write the body as numbered steps. Models follow numbered
sequences reliably, and a future reader of the skill can read
the steps as documentation.

## What skills are not

A skill is not code. Egghead does not load anything executable
from a skill file. The agent reads the body as instruction
prose, and any tool calls go through the agent's own
capabilities and Egghead's built-in or external MCP tools.

A skill is not a capability bypass. Adding `allowed-tools: Bash`
to a skill does not give an agent subprocess access; the agent
must already hold `proc.exec`, and the scopes have to match.

A skill is not global. A skill only resolves for agents whose
capabilities cover its `allowed-tools`. Two agents with
different capability sets see different skill lists, and that is
how the system stays honest about authority.

The rest of the authority story — the verbs, the scopes, the
sandbox — is in [Capabilities]({{< ref "capabilities" >}}).
