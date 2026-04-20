---
title: Research influences
weight: 60
---

Egghead didn't invent anything. Its design stitches ideas from two
largely-disconnected lineages — personal knowledge management, and
recent multi-agent systems research — into one running artifact.
This guide names both so you can trace where any particular design
decision came from.

A third lineage — capability-based security — shapes the agent
authority model and is documented at the end of the
[Capabilities guide]({{< ref "capabilities" >}}). It's referenced
briefly below and not repeated in full.

## Personal knowledge management

The idea that a knowledge graph should be atomic, linked, and
durable isn't new. It predates LLMs by decades. Three strands are
load-bearing for Egghead:

### Zettelkasten — Niklas Luhmann's slip-box

Niklas Luhmann was a 20th-century German sociologist who developed
a note-taking method using index cards kept in wooden slip-boxes
(*Zettelkästen*). Each card held one idea. Each card had a unique
identifier. Cards pointed at other cards by id. Luhmann accumulated
roughly 90,000 cards over his career and credited the system with
enabling his output — something like 50 books and 600 papers across
multiple disciplines.

The core moves of Zettelkasten:

- **Atomic notes.** One idea per card. Small enough to reason about
  in isolation, granular enough to recombine freely.
- **Stable identifiers.** A card's id doesn't change, so links don't
  break. Topic changes happen through re-linking, not rewriting.
- **Direct links between notes, not hierarchies.** No folders, no
  taxonomy. Connection is the structure.
- **Emergent sequencing.** Related cards tend to cluster; context
  emerges from link density rather than from pre-imposed organization.

Luhmann's own account — *Kommunikation mit Zettelkästen*,
published in 1981 and widely translated as "Communicating with
Slip Boxes" — argues that the slip-box is a genuine
*Kommunikationspartner*, a conversational partner rather than a
storage system. You talk *with* the box by writing cards that
respond to other cards; new connections surface during the writing.
Sönke Ahrens' 2017 book *How to Take Smart Notes* translated
Luhmann's method for a modern audience and is the most common
entry point into the tradition in English.

What Egghead inherits:

- Records are **atomic** — one idea per file.
- Records have **stable ids** that don't change when you move them.
- Links between records (`links:` and `[[wikilinks]]`) are the
  primary structure; directories are optional, and search plus
  backlinks matter more than where a file sits on disk.
- The two-way graph (forward links + backlinks) is treated as
  first-class query surface.

The step beyond Zettelkasten is that Egghead's "conversational
partner" isn't a metaphor for the filesystem — it's actual agents,
reading records, writing records, talking about records. The
slip-box became a staff.

### Second Brain — Tiago Forte

Tiago Forte's 2022 book *Building a Second Brain* popularized a
more project-oriented knowledge system with two acronyms worth
naming:

- **CODE.** Capture, Organize, Distill, Express. The pipeline view
  of how knowledge moves from in-the-world to in-your-head to
  useful-in-an-artifact.
- **PARA.** Projects, Areas, Resources, Archive. A four-bucket
  organization scheme keyed on *actionability* rather than topic.

Egghead doesn't adopt PARA wholesale — the system has record
*classes* instead (`durable`, `inbox`, `deliberation`, ...), which
are different axes. But the Second Brain ethos shows up in two
places:

- **Capture is cheap.** The `inbox` class exists because sometimes
  you want to write down "this fetched page might be useful later"
  without committing to making it permanent. The parser accepts
  records with no frontmatter and fills in defaults. Friction on
  capture is friction on the whole system.
- **Distillation is separate.** Durable records are the result of
  a decision, not a default. The distinction between `inbox` and
  `durable` classes names the distillation gate explicitly. See the
  [Record classes guide]({{< ref "record-classes" >}}).

### Evergreen notes — Andy Matuschak

Andy Matuschak's working notes, published at
[andymatuschak.org/notes/](https://andymatuschak.org/notes/), are
a practical instantiation of Luhmann-adjacent practice in the era
of wikilinks and static-site publishing. The core ideas:

- **Evergreen notes should be atomic.** Permanent notes about
  single concepts, each standing on its own.
- **Evergreen notes should be concept-oriented, not source-oriented.**
  A note titled "graph topology affects multi-agent coordination
  quality" is evergreen; "notes from the MARBLE paper" is not.
- **Evergreen notes should be densely linked.** The density is
  what creates value — unlinked notes are lost tips.

What Egghead inherits: the sensibility that the record is the unit
of thought. A record's permanence comes from being about an idea,
not about an artifact. Backlinks and search make the density pay
off at retrieval time.

### Tools in this lineage

Obsidian, Logseq, and Roam Research are Egghead's closest cousins
on the tooling side — Markdown (or Markdown-adjacent) notes,
`[[wikilinks]]`, graph views, plain-files-on-disk. Egghead is
deliberately compatible with this class of tool: your records
directory can be an Obsidian vault, and vice versa.

The distinction: in Obsidian the humans are the only participants
in the graph. In Egghead, agents are participants too — they read
records, write records, cite records by wikilink, and survive each
other. The agent layer is a graft onto the PKM stock, not a
replacement for it.

## Multi-agent systems research

Where the PKM lineage gives Egghead its substrate, the multi-agent
research of the past three years gives it its coordination model.
The findings below are from papers that have shipped and been
peer-reviewed; several are from 2025 alone. The field moves fast.

### MultiAgentBench / MARBLE — topology matters

*MultiAgentBench: Evaluating the Collaboration and Competition of
LLM Agents*, Zhu et al., ACL 2025
([arXiv:2503.01935](https://arxiv.org/abs/2503.01935)).

MARBLE is the first broad benchmark for multi-agent collaboration
topology. It tests four coordination shapes — star, tree, chain,
graph-mesh — across research, coding, database, bargaining, and
Minecraft scenarios, scoring each on *milestone-based KPIs*
(granular coordination quality, not just final task success).

The headline finding, paraphrased from the paper: "The difference
between star and graph topology is larger than the difference
between some model choices." In research scenarios, graph-mesh
(fully connected, peers see each other) outperforms star (central
planner dispatches to workers) by a meaningful margin.

What Egghead takes from this:

- **Shared transcript, not dispatch.** Every agent in a room sees
  every message. No central coordinator sits between peers.
- **Peer self-selection, not central assignment.** The coordinator
  narrows candidates structurally and by relevance; agents decide
  whether to speak. Graph topology, sparse activation.
- **Milestone-based evaluation.** Deliberation records and
  transcript records map cleanly onto MARBLE's milestone KPI shape,
  making this style of eval portable to Egghead-native workflows.

### MAST — the failure taxonomy

*Why Do Multi-Agent LLM Systems Fail?*, Cemri et al., Berkeley,
NeurIPS 2025 Datasets & Benchmarks (spotlight)
([arXiv:2503.13657](https://arxiv.org/abs/2503.13657)).

The paper annotated 150+ execution traces from five multi-agent
frameworks (MetaGPT, ChatDev, AG2, HyperAgent, AppWorld) with
inter-annotator agreement κ = 0.88. The central finding is sobering:
**multi-agent systems fail ~66% of the time on average, and the
same model in a single-agent setup often outperforms its
multi-agent version.** The failures are architectural, not model-
level.

MAST categorizes failures into three classes and fourteen modes:

- **FC1 Specification issues** (41.8%) — ambiguous prompts,
  repetition, unawareness of termination conditions.
- **FC2 Inter-agent misalignment** (36.9%) — information
  withholding, ignored input, reasoning-action mismatch.
- **FC3 Task verification** (21.3%) — premature termination,
  missing or incorrect verification.

The killer result: adding a single high-level verification step to
ChatDev yielded **+15.6% improvement** on the ProgramDev
benchmark. Same model, better design. Architecture outweighs model
choice when the architecture has gaps.

What Egghead takes from this:

- **Shared transcript closes several FC2 modes automatically** —
  information withholding and conversation reset don't have room to
  manifest when every agent sees every message in one log.
- **Handoff-over-compaction closes FC1.4 (loss of conversation
  history)** by summarizing into a durable deliberation record
  rather than silently dropping the oldest messages.
- **FC3 (verification) is an honest gap.** Egghead doesn't yet
  have a structural verification layer. It's an open area the
  research says is worth addressing.

### AutoGen — what not to do with speaker selection

Microsoft AutoGen (and its AG2 successor) uses a `GroupChatManager`
that prompts an LLM to choose the next speaker from the roster.
AutoGen's own documentation flags the default `auto` mode as
fragile: the LLM can hallucinate a speaker not in the participant
list, throwing an exception; the selection call is expensive; and
the manager is a single point of failure.

Egghead's coordinator deliberately avoids this shape:

- The structural filter is zero API-cost. `@mentions` and mute
  resolve without a model call.
- Relevance scoring for open messages uses TF-IDF against agent
  tags and dispositions — classic information retrieval, no LLM
  in the loop.
- Agents opt *out* (via `/pass`) rather than being selected *in*.
  A "speaker not found" failure has no surface to occur on.

AutoGen is the contrast case, not the influence. Its failure modes
are what Egghead's activation design is shaped against.

### Talk Isn't Always Cheap — the conformity problem

*Talk Isn't Always Cheap*, Wynn, Satija, and Hadfield, ICML MAS
Workshop 2025 ([arXiv:2509.05396](https://arxiv.org/abs/2509.05396)).

The paper documents a disconcerting finding: in serial multi-agent
debate, stronger models adopt weaker models' wrong answers under
peer pressure more often than weaker models learn from stronger
ones. The asymmetry runs the wrong way — capable agents flip from
correct positions when exposed to persuasive-but-incorrect peers.

What Egghead takes from this:

- **`/pass` reduces additive noise.** An agent with nothing new to
  say yields rather than piling on. This doesn't prevent sycophantic
  agreement (that's its own problem), but it does prevent the
  "everyone chimes in whether they have something or not" dynamic
  that conformity studies implicate.
- **Parallel mode (`@jam`) for independent framings.** When you
  want variety rather than consensus, agents don't see each other's
  in-flight output. The cacophony is the point.
- **The Heckler pattern is a partial mitigation.** An agent whose
  disposition is structured dissent isn't a general solution to
  conformity — the literature shows agents flip from correct
  positions under persuasive-but-wrong peer pressure, and a heckler
  who agrees with the wrong peer is no help — but it's a real tool
  against groupthink in practice.

### Stigmergy

*Stigmergy* is the biological term for coordination through shared
environmental state — ants leaving pheromone trails, termites
responding to the mound's current state rather than to each other
directly. Coordination emerges from the environment, not from
signaling between agents.

The record store is Egghead's stigmergic substrate. Agents read
records written by other agents (or by you). They write records in
response. They cite each other's records via wikilinks. Coordination
happens through the persistent graph, not through direct
agent-to-agent messaging alone.

This is a deliberate inversion of message-passing-centric
multi-agent systems. The "environment" isn't passive — it's the
knowledge graph, searchable, versionable, durable. Agents come and
go; the graph accumulates.

### Adjacent work worth naming

- **MacNet** (Qian et al., ICLR 2025,
  [arXiv:2406.07155](https://arxiv.org/abs/2406.07155)) — multi-agent
  collaboration organized as a DAG, showing that irregular topologies
  outperform regular ones and identifying a collaborative scaling
  law (performance follows logistic growth as agents scale).
- **AgentNet** (NeurIPS 2025, [arXiv:2504.00587](https://arxiv.org/abs/2504.00587))
  — decentralized DAG with RAG-augmented dynamic routing; no central
  critic. Philosophically close to the "records are the graph"
  stance.
- **G-Designer** (ICML 2025 spotlight) — adaptive topology design
  via graph neural networks; shows no single topology is optimal
  across tasks, so routing between topologies matters.

Egghead doesn't implement these directly. They inform the
long-horizon direction: if the single-coordinator model ever
bottlenecks, topology routing (cheap planner decides the shape per
task) is the shape of the next move.

## Capability systems

Egghead's capability model — `resource.verb` grants, parameter
scoping, attenuation-only delegation — draws from a third lineage:

- **OpenBSD pledge/unveil** — declaration style for process
  privilege reduction.
- **FreeBSD Capsicum** — fine-grained, attach-to-resource
  capabilities with irreversible restriction.
- **Google Macaroons** — chained-caveat delegation tokens, provably
  subset-only.

The full discussion of how each influenced the design is in the
"Inspirations" section of the
[Capabilities guide]({{< ref "capabilities" >}}), including the
original sources.

## What Egghead is explicitly not

Naming the opposite helps locate the design. Egghead is
*not*:

- **An agent framework with a knowledge base bolted on.** Most
  multi-agent frameworks (CrewAI, LangGraph, and others) treat
  agents as the primitive and storage as a subordinate component.
  Egghead inverts this: the record store is the institution,
  agents are staff.
- **A memory system for a single coding agent.** Coding agents
  (Claude Code, OpenCode, Amp, Codex) are single-agent tools with
  local context. Egghead can be consulted by them over MCP, and
  benefit from them as clients, but it is not trying to be one.
- **A delegation-chain workflow engine.** Star and tree topologies
  are explicitly what the MARBLE findings argue against for
  collaborative tasks. Egghead's coordinator gates activation, not
  communication; peers see each other; delegation happens through
  `@mention` and `/handoff`, not through a dispatcher.

These aren't criticisms of those systems — they solve different
problems. But locating Egghead against them clarifies what its
design is *for*.

## See also

- [Records]({{< ref "records" >}}) — the atomic, linked, durable
  substrate the PKM lineage shaped
- [Chat rooms]({{< ref "chat-rooms" >}}) — the graph-topology,
  sparse-activation, shared-transcript coordination model the
  multi-agent lineage shaped
- [Capabilities]({{< ref "capabilities" >}}) — the three-lineage
  authority model (pledge/unveil + Capsicum + Macaroons)
