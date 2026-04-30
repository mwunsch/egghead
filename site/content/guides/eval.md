---
title: Evals
section: Evaluation
weight: 42
summary: Score a roster of agents against a task. Milestone-based KPI ported from MultiAgentBench (MARBLE), plus communication, planning, and category-specific dimensions.
---

`egghead eval` runs a roster of agents against a task in an
ephemeral chat room and grades the resulting transcript with a
Judge agent. The grading methodology is ported from
[MultiAgentBench (MARBLE)](https://arxiv.org/abs/2503.01935),
the first broad benchmark for multi-agent collaboration, so a
run record contains numbers that line up methodologically with
the published literature.

This is the part of Egghead where you get to test claims
empirically rather than vibe-check them. Frameworks tend to
ship one or two prebuilt evals that demonstrate the framework
itself looks good; Egghead instead gives you the same scoring
rig the research literature uses, against your own roster, so
that questions like *"is the critic agent I just added actually
pulling its weight?"* have a measurable answer.

A successful run produces two records in your store. One is
the transcript of the conversation as a `class: transcript`
record. The other is a durable run record at
`eval-runs/<timestamp>-<hash>` tagged
`[eval, run, <category>]`, with KPI and per-dimension scores
in the frontmatter and a milestone breakdown in the body.

## Commands

```bash
egghead eval list                           # bundled tasks
egghead eval run <task-id>                  # run against your agents
egghead eval run <task-id> --roster task    # run against task-bundled personas
egghead eval runs                           # past runs in the store
egghead eval report <run-id>                # re-render a run record
egghead eval compare <run-a> <run-b>        # write a comparison record
```

## Roster modes

The `--roster` flag selects who participates.

`--roster user` is the default. It joins every `class: agent`
record from your store to the eval room. Use this mode to
evaluate your own roster.

`--roster task` spawns transient agent processes from personas
declared by the task itself (for example, MARBLE's reference
research personas in `priv/eval/personas/`). These agents live
only for the duration of the run, are never written to your
records directory, and disappear when the room stops. Use this
mode to compare your roster against the task's reference roster
on the same prompt.

The `compare` subcommand was built for exactly this kind of
A-vs-B run; running both modes against the same task and then
comparing the two run ids tells you whether your specialization
out-performs MARBLE's generic researchers, or whether the
literature's baseline is still ahead.

## Bundled tasks

| Task                          | Category    | Notes |
|-------------------------------|-------------|-------|
| `research/profile-1`          | research    | MARBLE profile 1 — DELLA/DARE LLM model merging. |
| `research/profile-2`          | research    | MARBLE profile 2 — CybORG. |
| `research/profile-3`          | research    | MARBLE profile 3 — multi-stage recommender systems. |
| `bargaining/toyota-corolla`   | bargaining  | Buyer/seller negotiation. |

MARBLE's database, Minecraft, werewolf, and coding tasks are
not ported. The first three need environment sandboxes Egghead
does not ship. The coding tasks expect an action-first
execution model — every agent's turn is a programmatic
`agent.act(task)` call — that does not match Egghead's
chat-room turn semantics, and porting the tasks without
porting that execution model produces deadlock rather than a
comparable result.

## Scoring

Each run produces three core scores plus category-specific
dimensions.

### Core dimensions

**KPI** is the milestone-attribution score:
`(1 / (N × M)) × Σⱼ nⱼ`, where N is the agent count, M is the
total number of milestones, and nⱼ is the number of milestones
agent *j* contributed to. KPI measures load distribution. A
run that achieves every milestone with one agent doing all the
work scores lower than a run that achieves the same milestones
with even contribution across the roster. This is by design;
MARBLE is measuring collaboration quality, not task success
alone.

**Communication** is a 1–5 rating of clarity and information
exchange.

**Planning** is a 1–5 rating of role clarity and task
alignment.

### Research-task dimensions

For tasks in the `research` category, the Judge also scores:

- **Innovation** — 1–5
- **Safety** — 1–5
- **Feasibility** — 1–5

These three are independent. A common pattern in research runs
is high Innovation paired with low Feasibility — the proposal
is novel but hard to execute — which is genuine signal worth
reading on its own.

### Bargaining-task dimensions

For tasks in the `bargaining` category, the Judge produces
per-side effectiveness, progress, and interaction scores for
each participant.

All scores land in the run record's frontmatter `meta` block,
queryable from code:

```elixir
Egghead.Eval.list_runs()
|> Enum.filter(& &1.meta["category"] == "research")
|> Enum.map(&{&1.id, &1.meta["feasibility"]})
```

## The Judge

The Judge is a built-in agent that follows the same record-
shadowing pattern as `index`. It is always running, it uses
your configured `default_model`, and it grades transcripts
against milestone lists with prompts ported verbatim from
MARBLE's `evaluator_prompts.json`.

Judge is declared `quiet: true, idle: true` in its frontmatter,
so it does not crowd ordinary chat rooms. An eval run invites
Judge into the ephemeral room it opens for the run, where it
sits silently while the user roster works the task; once the
turns finish, the runner prompts Judge directly to produce the
JSON verdict. The two properties — quiet and idle — are
documented on the [Agents]({{< ref "agents" >}}#quiet-and-idle-agents)
page; the eval pipeline is the canonical example of why both
exist.

To use a different model for the Judge in a single run:

```bash
egghead eval run research/profile-1 --judge anthropic/claude-opus-4-7
```

To override the Judge's disposition, model, or capabilities
entirely, write a record with `id: judge` and `class: agent`:

```yaml
---
id: judge
class: agent
model: anthropic/claude-sonnet-4-6
capabilities: [records.read]
quiet: true
idle: true
tags: [eval, judge]
---

You are the Judge. You grade multi-agent transcripts...
```

As soon as that record exists, the built-in Judge steps aside
and yours runs in its place. Keep `quiet: true` and
`idle: true` unless you actually want your Judge participating
in regular rooms — they are what keep the grader off the
floor.

## Writing your own task

A task is a Markdown record. The frontmatter declares the
milestones and required capabilities; the body is the prompt
sent to the room.

```markdown
---
id: custom/design-review
title: "Design review: caching layer"
category: research
difficulty: medium
required_capabilities: [records.read]
dialogue_mode: open
milestones:
  - "Identify at least three concrete risks."
  - "Distinguish blocking risks from deferrable risks."
  - "Cite at least two existing records as context."
  - "Surface unresolved questions that need a human decision."
---

# Design review: caching layer

[paste the design doc, or wikilink a record]

Work through it as a team...
```

Capability gating is by union: the task runs if and only if
the union of capabilities across the roster covers
`required_capabilities`. No single agent has to hold every
verb; a roster where one agent reads and a different agent
writes is fine for a task that requires both. If the union
falls short, the runner exits with a message that names which
capability is missing — no token spend on a doomed run.

## Reading a run record

```markdown
# Research · research/profile-1 · 2026-04-21-b7c9

**KPI:** 0.40 · **Communication:** 5/5 · **Planning:** 5/5 ·
**Feasibility:** 3/5 · **Innovation:** 4/5 · **Safety:** 4/5

**Roster:** researcher-p1-1, researcher-p1-2, ...
**Run:** 10 turns · 218s · Tokens: 465K in / 14.8K out

## Milestones

- [x] Conducted literature review of model merging methods —
      _researcher-p1-3, -p1-1, -p1-2_
- [x] Formulated concrete research question on inference-time
      delta parameter routing — _researcher-p1-3_
- [x] ...

## Per-agent contribution

researcher-p1-3 ██████░░░░  0.56 (5 of 9)  200K tok
researcher-p1-5 ██████░░░░  0.56 (5 of 9)  168K tok
...

## Judge's rationale

Identified 9 candidate milestones; 9 achieved. ...
```

A few things to look at when you read one of these.

The score constellation matters more than any one number.
Innovation 4 with Feasibility 3 is "novel proposal, hard to
execute"; Communication 5 with Planning 3 is "messages were
clear, but the role distribution wasn't."

The per-agent contribution bars make load distribution
visible. A roster where two agents do nearly all the work and
one no-shows produces a different system than a roster with
even contribution, even when the KPI ends up the same.

The token-accounting line is worth reading too. Egghead
sessions re-read the room's transcript on every turn, which is
why the input/output ratio is usually high. Watching which
agent accumulates the most input tokens tells you which agent
is carrying the conversation, even if the milestone bars
suggest otherwise.

The transcript wikilink at the bottom of the record is the
ground truth. If a milestone count looks wrong, the transcript
is what to check.

## Recipes

### Did a disposition change actually help?

```bash
egghead eval run research/profile-1                            # → run-id A
# edit an agent's disposition or capabilities
egghead eval run research/profile-1                            # → run-id B
egghead eval compare A B
```

`compare` writes a durable comparison record with KPI and
per-dimension deltas. Run more than once before drawing
conclusions; any single run has variance.

### How does my roster compare to the benchmark?

```bash
egghead eval run research/profile-1                            # your roster
egghead eval run research/profile-1 --roster task              # MARBLE roster
egghead eval compare <yours> <marble>
```

If MARBLE's reference roster consistently scores higher on a
task you expect your roster to handle well, your dispositions
need work. If yours scores comparably or higher, that is
evidence the specialization paid off.

## Limitations

A few honest gaps in the current implementation.

Grading is post-hoc. The Judge runs after the room stops, not
during. Streaming-judge during the run is not implemented.
This matches MARBLE's reference implementation, so the
limitation is methodological rather than a deviation from the
literature.

Variance is real. A single run reflects one realization of the
roster's behavior. The MARBLE paper reports means over many
runs; you should do the same before drawing conclusions.
`--runs N` is on the roadmap.

The Judge is fallible. It is an LLM reading a transcript;
agents that produce confident-looking but wrong work can fool
it. Milestone attribution is more robust than the 1–5
dimension ratings because it is grounded in specific quoted
claims, but no LLM grader is infallible. Compare to your own
read of the transcript when numbers surprise you.

Coding tasks are deliberately not ported. Egghead's chat-room
turn model — "speak when you have something substantive to
add" — does not match MARBLE's coding execution model
(`agent.act(task)`), and porting the tasks without porting the
execution model produces a deadlock rather than a comparable
result. Building an action-first execution mode for coding
tasks is possible but would be a different system pretending
to be Egghead.

## See also

- [Chat rooms]({{< ref "chat-rooms" >}}) covers the
  coordination model an eval exercises.
- [Agents]({{< ref "agents" >}}) covers how dispositions
  shape role selection in a run.
- [Capabilities]({{< ref "capabilities" >}}) covers the
  union-gating that `required_capabilities` enforces.
- [Consultation]({{< ref "consultation" >}}) is the same
  ephemeral-room shape without a Judge attached.
- [Research influences]({{< ref "research-influences" >}})
  has the full bibliography for MARBLE and the rest of the
  multi-agent literature Egghead draws from.
