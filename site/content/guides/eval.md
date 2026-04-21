---
title: Evals
weight: 35
---

`egghead eval` asks a question Egghead needs to answer about itself:
how well do *your* agents collaborate, and does the graph-topology
story actually pay off for the work you're doing? It's inspired by
[MultiAgentBench (MARBLE)](https://github.com/ulab-uiuc/MARBLE),
Zhu et al., ACL 2025
([arXiv:2503.01935](https://arxiv.org/abs/2503.01935)) — the first
broad benchmark for multi-agent collaboration — and packages the
same milestone-based scoring methodology as a fifth Egghead
interface, peer to the TUI, CLI, web, and MCP.

You point it at a task. It spins up an ephemeral chat room, posts
the prompt, lets the agents converge, and grades the transcript with
a Judge agent. The result is a durable record in your store you can
link to, query, and compare against later runs.

## Why you'd use it

Two distinct questions, both worth measuring:

1. **"How good is my roster at this kind of work?"** You wrote a
   Scout, an Archivist, a Heckler. Do they cohere on a research
   synthesis task? Who pulls their weight? Who `/pass`es when they
   should be contributing? Run against your own agents and find out.

2. **"How does Egghead-as-a-MAS compare to the benchmark?"** Run
   MARBLE's shipped research personas against a MARBLE-ported task
   and you have numbers that line up — at least methodologically —
   with the published literature. Useful for internal design
   iteration, useful for publishing if you care to.

Neither question has a good answer today without infrastructure like
this. The agent design is expressive enough that *you can't vibe-check
it*; it needs actual runs with actual scoring.

## The 30-second version

```bash
egghead eval list                           # what's bundled
egghead eval run research/profile-1         # against your roster
egghead eval run research/profile-1 --roster task
                                            # against MARBLE personas
egghead eval runs                           # past runs in the store
egghead eval report <run-id>                # re-render a report
egghead eval compare <run-a> <run-b>        # side-by-side
```

A successful run produces:

- A **durable record** at `eval-runs/<timestamp>-<hash>` in your
  records directory, tagged `[eval, run, <category>]`. Frontmatter
  has KPI, the three MARBLE dimension scores, per-category scores,
  roster, token accounting. Body has a GFM task-list of milestones
  with per-agent attribution, an ASCII per-agent contribution chart,
  footnoted evidence citations, and a link to the transcript.
- A **transcript record** (`class: transcript`) — the full
  conversation, the normal way any chat room is saved. Readable in
  the TUI or web, or `/join`-able if you want to pick up where the
  agents left off.

Both are records. They show up in search, backlinks, and wikilink
traversal exactly like anything else you write. Eval is a first-class
citizen of the record store, not a parallel silo.

## The two roster modes

`--roster` decides who sits at the table.

### `--roster user` — evaluate your agents (the default)

The runner enumerates `class: agent` records in your store and joins
every one of them to the eval room. This is the answer to "how is
*my* setup doing?" The tasks are written to be agent-identity-agnostic
— they describe outcomes ("propose a concrete research direction",
"ground the proposal in prior work") rather than demanding a
specific cast ("the PI should …"). Whoever you have plays whatever
role fits their disposition.

This is the mode that tells you whether Scout and Archivist are
actually complementary or whether one of them is dead weight on
this kind of task.

### `--roster task` — evaluate Egghead against the benchmark

Some bundled tasks (the MARBLE ports) ship with their own personas
in `priv/eval/personas/`. When you pass `--roster task`, the runner
spawns those personas as **transient agent processes** — they live
only for the duration of the run, they're never written to your
store, and they vanish when the room stops. The Room is scoped to
just those personas; your own agents don't participate.

This is the mode that gives you numbers comparable (methodologically,
not operationally) to MARBLE's published results. It also answers a
more interesting variant question: *does your roster do better or
worse than MARBLE's generic researchers on the same prompt?* Run
both modes on the same task, compare KPIs.

The personas shipped with the research tasks are MARBLE's own
profiles, ported verbatim from their YAML configs. They carry
MIT-license attribution in their frontmatter `source:` field.

## The Judge

The Judge is a synthetic agent — the same pattern as Index. It's
always running, it uses your configured `default_model`, and it
grades transcripts against milestone lists using prompts ported
verbatim from MARBLE's `evaluator_prompts.json`.

### Three dimensions, scored independently

Every run gets three scores derived from MARBLE's evaluator:

- **KPI** — the headline milestone-attribution score. The Judge reads
  the transcript, extracts the concrete milestones achieved, and
  attributes each to the agent ids that contributed. KPI is then
  `(1 / (N × M)) × Σⱼ nⱼ` where N is the agent count, M is the total
  milestones, and nⱼ is the number of milestones agent *j*
  contributed to. **KPI is a load-distribution metric, not a
  completion metric.** A run that achieves all milestones but has
  one agent doing all the work will score lower than a run where
  everyone pitches in evenly. This is by design — MARBLE is measuring
  collaboration quality, not task success alone.
- **Communication** — 1-to-5 rating of clarity, information exchange,
  efficiency. A flat rating, one number, from the Judge reading the
  transcript.
- **Planning** — 1-to-5 rating of role clarity, task alignment,
  autonomy. Also flat.

Plus category-specific scores where applicable:

- **Research tasks**: Innovation, Safety, Feasibility (each 1-to-5).
  The most interesting of these is usually Feasibility — the Judge
  will happily rate a proposal high on Innovation and much lower on
  Feasibility, which is useful signal.
- **Bargaining tasks**: per-side effectiveness / progress /
  interaction scores for buyer and seller independently.

All scores land in the run record's frontmatter `meta`. Query by
them; compare runs; track deltas as you iterate on agent
dispositions.

### Overriding the Judge

Like Index, the Judge is shadowed by any `class: agent` record in
your store with `id: "judge"`. Drop one in:

```markdown
---
id: judge
class: agent
model: anthropic/claude-sonnet-4-6
capabilities: [records.read]
tags: [agent, eval, judge]
---

You are the Judge. You grade multi-agent chat transcripts against a
milestone checklist. Return the exact JSON the caller requests, no
prose, no markdown fences…
```

…and your disposition replaces the built-in one. For a one-off
model swap without touching records, `--judge provider/model`:

```bash
egghead eval run research/profile-1 --judge anthropic/claude-opus-4-7
```

Different model for the Judge than for the agents is often a good
idea. Use a small model as a persona and a larger one as the Judge,
or vice-versa to control for model strength.

## Tasks that ship

```bash
egghead eval list
```

Currently bundled:

- **research/profile-1** — MARBLE's profile 1. 5 researcher personas
  collaborate on a novel research direction given a paper
  introduction on LLM model merging (DELLA/DARE).
- **research/profile-2** — profile 2. Paper introduction on CybORG
  (autonomous cyber operations gym).
- **research/profile-3** — profile 3. Paper introduction on
  multi-stage recommender systems.
- **bargaining/toyota-corolla** — a buyer and a seller negotiate the
  price of a used 2011 Toyota Corolla. Ported from MARBLE's `world`
  (bargaining) config.

The research tasks are the core of MARBLE's findings on graph-vs-
star topology and are the most relevant to what Egghead is actually
for. The bargaining task is included for its adversarial dynamics —
one agent has a goal, another has the opposite goal — which is
structurally different from the cooperative-research cases and a
useful sanity check that the dialogue modes hold up under
disagreement.

MARBLE's database, Minecraft, and werewolf tasks aren't ported —
they require environment sandboxes Egghead doesn't ship. Their
coding tasks aren't yet ported; they require workspace and
`shell.exec`/`fs.write` capability wiring beyond the records-only
baseline. Both are reasonable future additions.

### Writing your own tasks

A task is markdown with frontmatter. Drop a file in a directory of
your choice and point the runner at it:

```markdown
---
id: custom/design-review
title: "Design review: caching layer"
description: "Given a design doc, agents produce a list of risks and open questions."
category: research
difficulty: medium
required_capabilities: [records.read]
dialogue_mode: open
milestones:
  - "Identify at least three concrete risks in the proposed design"
  - "Distinguish risks that block shipping from risks that can be deferred"
  - "Cite at least two existing records from the store as context"
  - "Surface unresolved questions that need a human decision"
---

# Design review: caching layer

Here is the proposed design:

[paste design doc here, or wikilink to a record]

Work through it as a team. Raise risks. Cite what you know. Flag
what you don't. We're not looking for consensus; we're looking for
coverage.
```

Capability-union gating enforces requirements: the task can run iff
the union of grants across the roster covers `required_capabilities`.
No single agent needs every verb. If the requirement isn't met, the
runner skips with a readable error naming what's missing — it doesn't
burn tokens on a doomed run.

## Reading a run record

Every run produces a markdown record. The shape, from a real run:

```markdown
# Research · research/profile-1 · 2026-04-21-b7c9

**KPI:** 0.40 · **Communication:** 5/5 · **Planning:** 5/5 ·
**Feasibility:** 3/5 · **Innovation:** 4/5 · **Safety:** 4/5

**Roster:** researcher-p1-1, researcher-p1-2, researcher-p1-3,
researcher-p1-4, researcher-p1-5
**Run:** 10 turns · 218s · judge (default) · Tokens: 465.5K in / 14.8K out

## Milestones

- [x] Conducted literature review of model merging methods
      (DELLA, TIES, DARE) — _researcher-p1-3, -p1-1, -p1-2_
- [x] Formulated concrete research question on inference-time delta
      parameter routing — _researcher-p1-3_
- [x] …

## Per-agent contribution

researcher-p1-3 ██████░░░░  0.56 (5 of 9)  200.4K tok
researcher-p1-5 ██████░░░░  0.56 (5 of 9)  168.4K tok
researcher-p1-2 ██████░░░░  0.56 (5 of 9)  25.9K tok
researcher-p1-4 ██░░░░░░░░  0.22 (2 of 9)  60.6K tok
researcher-p1-1 █░░░░░░░░░  0.11 (1 of 9)  25.0K tok

## Judge's rationale

Identified 9 candidate milestones; 9 achieved. …
```

What to look at:

- **The score constellation, not any one number.** Innovation 4 with
  Feasibility 3 is a classic Judge signal: "novel proposal, hard to
  execute." Communication 5 with Planning 3 means the messages were
  clear but the role distribution wasn't. Compare across dimensions
  before drawing conclusions from KPI alone.
- **The per-agent bars.** A roster where two agents do all nine
  milestones and one no-shows is a different system than one where
  responsibility is evenly distributed, even if the KPI is the same.
  The bars make it visible.
- **Token accounting.** Egghead sessions re-read the transcript on
  every turn, which is why the run above has 465K tokens *in* against
  14.8K *out* — a 32:1 ratio. The agents write concisely but see a
  lot. Watch which agent accumulates the most input tokens; that's
  usually the one carrying the conversation.
- **The transcript wikilink.** Click through. The milestones are a
  summary; the transcript is what happened. If something in the
  milestone list looks wrong, the transcript is the source of truth.

## Practical recipes

### Track whether a disposition change helped

1. Run a baseline:
   `egghead eval run research/profile-1` → run-id `A`.
2. Edit your agent's disposition — soften the Heckler, add a new
   capability, swap models.
3. Run again: → run-id `B`.
4. `egghead eval compare A B`. Writes a durable comparison record.
   KPI delta and per-dimension deltas show whether the change
   actually moved the needle.

Run this multiple times before drawing conclusions — any single run
has variance. MARBLE reports means over many runs.

### Calibrate your roster against the benchmark

1. `egghead eval run research/profile-1` — your agents on a MARBLE
   research prompt.
2. `egghead eval run research/profile-1 --roster task` — MARBLE's
   personas on the same prompt.
3. Compare. If the MARBLE personas consistently outscore your
   roster on tasks your roster is supposed to be good at, the
   dispositions aren't pulling their weight. If yours score
   comparably or better, that's evidence the investment in
   specialization paid off.

### Stress-test a specific dimension

The MARBLE research evaluator scores Innovation, Safety, and
Feasibility independently. If you care about a specific one —
say your work is safety-critical and Feasibility is the number
that matters — watch that dimension across runs, not KPI. The
frontmatter `meta` makes this queryable:

```elixir
Egghead.Eval.list_runs()
|> Enum.filter(& &1.meta["category"] == "research")
|> Enum.map(&{&1.id, &1.meta["feasibility"]})
```

### Replay a transcript with a different Judge

Under the hood the Judge grades a saved transcript — the same one
persisted as `class: transcript`. If you want to re-score an old run
with a different Judge model without re-running the agents (no token
burn), that's a v1.1 feature; for now, re-running with the new
`--judge` flag is the path.

## Limits to know about

- **Post-hoc grading at v1.** MARBLE's paper describes "continuous"
  judging; the reference implementation grades after the fact, and
  so does Egghead. Live streaming-judge is a UX layer we haven't
  built. In practice post-hoc is what produces the published
  numbers, so this is a matches-literature limit, not a correctness
  limit.
- **Variance.** Any single run tells you about *one* realization of
  the agents' behavior. Draw conclusions from distributions. `--runs
  N` is on the roadmap; for now, run by hand and read multiple
  records.
- **Capability gating is enforced at dispatch time.** If a task
  `requires: fs.write` and your roster has `records.read` only, the
  runner skips with a clear message. This is a feature — you don't
  want to burn tokens on a run that can't succeed — but it means
  low-tier tasks (`records.read`-only) are the ones you can always
  run without thinking about grants.
- **The Judge can be fooled.** It's an LLM reading a transcript. If
  your agents produce confident-looking but wrong work, the Judge
  may score it high. Milestone attribution is more robust than the
  1-to-5 dimension ratings because it's grounded in specific quoted
  claims, but no LLM grader is infallible. Compare to your own read
  of the transcript when numbers surprise you.

## See also

- [Chat rooms]({{< ref "chat-rooms" >}}) — the coordination model
  eval exercises
- [Agents]({{< ref "agents" >}}) — how dispositions shape which
  agent plays which role in a run
- [Capabilities]({{< ref "capabilities" >}}) — the grant model that
  capability-union gating enforces
- [Research influences]({{< ref "research-influences" >}}) — MARBLE
  is covered in depth there, alongside the rest of the multi-agent
  lineage Egghead draws from
- [Consultation]({{< ref "consultation" >}}) — the other "ephemeral
  room, structured result" shape. Eval is consultation with a grader
  and a task definition
