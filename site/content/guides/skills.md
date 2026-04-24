---
title: Skills
weight: 19
---

A skill is a packaged way of doing something — instructions for a
common task, plus a declaration of the tool dependencies that task
needs. Skills are composable: any [agent]({{< ref "agents" >}})
with the required capabilities can invoke one. They're portable:
drop a skill into a shared directory and every Egghead install
picks it up.

This guide covers where skills live, what goes in a `SKILL.md`, how
the capability check works at invocation time, and the CLI for
auditing them.

## Two sources, one index

Skills come from three places, all treated the same:

1. **The drop-zone directory** — default `~/.agents/skills/`,
   configurable as `skills_dir` in
   [config.yml]({{< ref "configuration" >}}). Each subdirectory
   containing a `SKILL.md` is a skill.
2. **Your record store, by class** — any record anywhere in the
   records directory with `class: skill` in its frontmatter.
3. **Your record store, by convention** — any file at
   `skills/<name>/SKILL.md` inside your records directory is
   auto-promoted to `class: skill` without needing the explicit
   frontmatter line.

All three are unified. `egghead skills list` shows them together;
agents discover them together; there's no difference in behavior
between them.

The drop-zone is for skills you want to share without bundling them
into your notes. The store paths are for skills that belong to this
particular project or graph. Pick whichever fits; you can move a
skill between sources later.

## Anatomy of a SKILL.md

```yaml
---
name: pr-review
description: Review a GitHub pull request for obvious issues.
allowed-tools: Bash(gh:*) Read Grep
compatibility: Best results with Claude Sonnet 4+ or equivalent.
---

# PR review

When asked to review a pull request:

1. Fetch the diff with `gh pr diff <number>` — don't try to look at
   individual files unless the diff is too large to process at once.
2. Scan for the usual: missing error handling, test coverage gaps,
   obvious security issues (SQL injection, XSS, unchecked redirects).
3. Cite specific file and line locations in your feedback.
4. Keep the summary tight. Lead with "what's good"; flag concerns
   next; end with "looks ready" or "one more round."
```

The frontmatter is small by design:

| Key             | Required | What it does                                     |
|-----------------|----------|--------------------------------------------------|
| `name`          | yes      | Skill id; lowercase + hyphens; ≤ 64 chars       |
| `description`   | yes      | One-line summary; ≤ 1024 chars; shown in `skills list` |
| `allowed-tools` | no       | Space-separated tokens declaring what this skill uses |
| `compatibility` | no       | Human-readable note about model/version fit     |

The body — everything after the second `---` — is the skill's
instruction set, free-form prose. This is required (empty bodies
fail validation) and is what the agent actually reads when invoking
the skill.

## `allowed-tools`

The `allowed-tools` field is a space-separated list of tokens in
Claude-Code-compatible syntax:

```yaml
allowed-tools: Bash(git:*) Bash(gh:*) Read Grep WebFetch(domain:github.com)
```

At skill-invocation time, Egghead parses each token into a
capability request:

| Token                           | Capability request                                 |
|---------------------------------|----------------------------------------------------|
| `Bash(git:*)`                   | `proc.exec{patterns: ["git:*"]}`                   |
| `Bash(rg)`                      | `proc.exec{cmds: ["rg"]}`                          |
| `Read`                          | `fs.read`                                          |
| `Grep`                          | `fs.read`                                          |
| `WebFetch(domain:github.com)`   | `net.get{hosts: ["github.com"]}`                   |
| `WebSearch`                     | `net.get{hosts: ["*"]}`                            |

The translation table covers the common Claude Code tools. Tokens
that don't map to a known tool surface as warnings in
`egghead skills check` — they're not errors, because a skill can
reference a tool Egghead hasn't learned about yet, but they do
flag "this token won't resolve to a capability check."

## Skills never widen capabilities

This is the rule that makes the system sound: a skill declaring
`allowed-tools: WebFetch` does not grant the invoking agent any
ability to fetch the web. The agent must already hold the matching
capability. The skill's declaration is a *requirement*, not a
*grant*.

At invocation time, Egghead checks the agent's held capabilities
against the skill's derived requirements. If the agent is missing
anything, the skill is filtered out of discovery for that agent.
The filter is silent — the skill just doesn't show up. No error,
no prompt, no widening path.

The practical effect: skills are safe to share. A skill that needs
`proc.exec{cmds: [git]}` will only run for agents you've explicitly
given that capability to. The author of the skill and the operator
of the node maintain a clean division: the skill says what it needs,
the operator decides who gets it.

See the [Capabilities guide]({{< ref "capabilities" >}}) for the
capability model itself — the risk tiers, the attenuation rules,
and how to grant capabilities to an agent.

## CLI

Three commands for day-to-day skill work:

```bash
egghead skills list                    # all skills, with source and description
egghead skills show pr-review          # full frontmatter + body for one skill
egghead skills check pr-review --agent scout
```

`check` is the useful one during development. It reports:

- Which `allowed-tools` tokens the agent's capabilities satisfy
- Which tokens the agent is missing
- A suggested `egghead agents grant` command to fill each gap
- Any tokens that didn't resolve to a known capability (warnings)

Run `check` before trying to invoke a new skill — it takes a few
seconds and saves you the "why didn't the skill show up" puzzle.

## Compatibility

The `compatibility:` field is free-form human-readable text.

```yaml
compatibility: Requires a model that can call tools. Tested with
  Claude Sonnet 4+, GPT-4o, and Gemini 2.0.
```

Egghead doesn't interpret it — there's no gate keyed off
compatibility. The value shows up in `skills show` output and in the
TUI skill picker so humans curating a skill know what to expect.
If you want hard enforcement based on model, do that in the
agent's disposition (or keep the skill out of that agent's reach
via capabilities).

## Authoring a skill

The minimum is frontmatter with `name` + `description` + a body:

```yaml
---
name: rebase-audit
description: Walk recent rebases and flag anything suspicious.
---

When asked to audit recent rebases:

1. Get the reflog for the last N days with `git reflog --date=iso`.
2. Identify rebase entries...
```

That's a valid skill. If it doesn't list `allowed-tools`, the
capability check is trivial (no requirements) and the skill is
available to any agent — though without a tool declaration, the
agent has to decide on its own what tools to reach for, which
defeats some of the point.

Practical guidance:

- **Be specific in `description`.** It's how agents and humans
  decide whether to invoke the skill. "Review a PR" is mediocre;
  "Review a GitHub PR for security issues and test coverage gaps"
  is useful.
- **Declare tools narrowly.** `Bash(git:*)` is better than `Bash`;
  `WebFetch(domain:github.com)` is better than `WebFetch`. Narrow
  declarations let operators grant narrow capabilities, which
  keeps the node safer.
- **Write the body as you'd write notes to a colleague.** Short,
  numbered steps. Concrete examples where the task is subtle.
  Models do well with this style.

## What skills are, and aren't

Skills are instruction sets with declared tool requirements. They
are not:

- **A plugin system.** Egghead doesn't load code from a skill.
  Skills are content; execution goes through the agent's held
  capabilities and Egghead's built-in or external MCP tools.
- **A capability-escape hatch.** Adding `allowed-tools: Bash` to
  a skill doesn't give an agent subprocess access. Capabilities are
  the gate; the skill declares need, not authority.
- **Global.** A skill only runs for agents whose capabilities cover
  its `allowed-tools`. Curating who has what stays under your
  control — per agent, per node.

The model is content-first: the valuable part of a skill is the
prose. The capability declaration is a compatibility hint, not a
mechanism. That's the design.
