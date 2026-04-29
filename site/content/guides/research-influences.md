---
title: Research influences
section: Background
weight: 60
summary: A bibliography. The PKM lineage, the 2023–2025 multi-agent literature, and the capability-system papers behind specific design decisions.
---

This is a bibliography rather than a manifesto. The point is to
make it easy to trace specific Egghead design choices back to
the prior art they came from, so that when something looks
unusual you can read the source and decide whether you agree
with the call.

The lineages worth knowing about, in roughly the order they
matter to the system: the personal-knowledge-management
tradition that gave Egghead the records-first shape, the
2023–2025 multi-agent research that pointed at graph topology
and capability-scoped roles, and the capability-systems
literature that shaped the authority model.

## Personal knowledge management

The notion of a knowledge graph as something that should be
atomic, linked, and durable is decades older than LLMs. Three
strands of that tradition shape the Egghead store directly.

### Zettelkasten

Niklas Luhmann was a 20th-century German sociologist who
developed a note-taking method using index cards in wooden
slip-boxes. Each card held one idea; each had a unique
identifier; cards pointed at other cards by id. Luhmann
accumulated roughly 90,000 cards over his career and credited
the system with enabling his published output of around fifty
books and six hundred papers across multiple disciplines.

The core moves of the Zettelkasten method are atomicity (one
idea per card), stable identifiers (so links don't break when
topics change), direct links between cards instead of folder
hierarchies, and emergent sequencing (related cards cluster
because they link to each other, not because they were
catalogued together).

Egghead inherits all four. Records are atomic, with one idea
per file. Records have stable ids that don't change when you
rename or move them. Links between records — `links:` and
`[[wikilinks]]` — are the primary structure. Forward links and
backlinks are both first-class queries. The directories where
the files happen to sit on disk are mostly an organizational
convenience.

- Niklas Luhmann, *Kommunikation mit Zettelkästen*, 1981.
- Sönke Ahrens, *How to Take Smart Notes*, 2017 — the most
  common English entry point.

### Building a Second Brain

Tiago Forte's 2022 book popularized a more project-oriented
take on personal knowledge management. The two acronyms worth
naming are CODE (Capture, Organize, Distill, Express), which
describes how knowledge moves from in-the-world to in-your-head
to in-your-output, and PARA (Projects, Areas, Resources,
Archives), which is a taxonomy for organizing what you store.

Egghead's record classes — `durable`, `inbox`, `transcript`,
`deliberation` — overlap the Capture and Organize parts of CODE
without prescribing the rest. We deliberately do not enforce a
PARA-style folder taxonomy because Egghead is meant to live
alongside whatever you already use, and the folder layout is
yours to choose.

### Evergreen notes

Andy Matuschak's publicly readable working notes at
[notes.andymatuschak.org](https://notes.andymatuschak.org/)
introduced the term "evergreen" for notes that develop
iteratively, get edited continuously, and become more refined
over time rather than being captured once and abandoned.
Egghead's `class: durable` records correspond.

## Multi-agent systems (2023–2025)

The multi-agent literature is moving fast enough that anything
written in early 2026 risks being out of date by the time
you read it. The papers below are the ones whose findings
landed in specific Egghead choices.

### MultiAgentBench (MARBLE)

Zhu et al., *MultiAgentBench: Evaluating the Collaboration and
Competition of LLM Agents*, ACL 2025
([arXiv:2503.01935](https://arxiv.org/abs/2503.01935)).

MARBLE was the first broad evaluation framework for
multi-agent collaboration. Egghead's `egghead eval` command
ports the milestone-based KPI scoring, the communication and
planning ratings, and the category-specific dimensions
(Innovation/Safety/Feasibility for research,
buyer/seller scoring for bargaining). MARBLE's reference
research personas ship as the `--roster task` mode. The full
mapping is in [Evals]({{< ref "eval" >}}).

The headline MARBLE finding that Egghead leans on is that
**graph topology out-performs star topology on research tasks**
when the coordination model is shared-transcript rather than
dispatcher-routed. The chat-room shape in Egghead is the
direct result.

### MAST: a taxonomy of multi-agent failure

Cemri et al., *MAST: A Taxonomy of Failure Modes in
Multi-Agent LLM Systems*, 2025
([arXiv:2503.13657](https://arxiv.org/abs/2503.13657)).

An empirical study of where multi-agent systems break in
practice. The headline finding is that **most multi-agent
failures are architectural, not model-level**. Adding a
stronger LLM rarely fixes a system that is failing at
coordination, role separation, or context handling — those
are infrastructure problems, not intelligence problems.

This is the paper whose conclusions justify investing in
supervision trees, capability-scoped roles, and explicit
handoff. If the failure mode is architectural, treating
failure as a runtime primitive is the response, which is
exactly what OTP gives you.

### Talk Isn't Always Cheap

Bhatt et al., *Talk Isn't Always Cheap: Conformity in LLM
Multi-Agent Systems*, 2025
([arXiv:2412.10859](https://arxiv.org/abs/2412.10859)).

A study of what happens when multiple LLM agents discuss a
question. The result, briefly: even capable models flip from a
correct position to an incorrect one under
persuasive-but-wrong peer pressure. Persona prompts help
slightly; capability differentiation — different agents
literally cannot perform each other's roles — helps more,
because role separation enforced by the runtime is harder to
talk around than role separation enforced by a prompt.

Egghead's [capability model]({{< ref "capabilities" >}}) makes
that role separation structural. An agent with `records.read`
cannot suddenly perform a write because a peer agent argued it
into doing so; the runtime simply will not let it. That choice
is partly a response to this paper.

## Capability-based security

The authority model in [Capabilities]({{< ref "capabilities" >}})
draws from three lineages. None of these were designed for LLM
agents, which is exactly why they generalize well.

### OpenBSD pledge and unveil

[`pledge(2)`](https://man.openbsd.org/pledge.2) restricts a
process to a list of allowed verbs;
[`unveil(2)`](https://man.openbsd.org/unveil.2) restricts the
parts of the filesystem those verbs can touch. Egghead's
`capabilities:` field is the pledge equivalent — what the
agent is allowed to do. Egghead's `sandbox:` and `in:` fields
are the unveil equivalent — where the agent is allowed to do
it. Both lists can only narrow over time.

OpenBSD's posture is also worth naming directly: 33 of
OpenBSD's 36 boot processes use `pledge`, while only 3 of 47
adopted FreeBSD's Capsicum (below). Simplicity drives
adoption, and we tried to keep the same posture: one capability
declaration per record, widening is a human edit, never a
runtime "allow once" prompt.

### FreeBSD Capsicum

Watson et al., *Capsicum: Practical Capabilities for UNIX*,
USENIX Security 2010
([paper](https://www.usenix.org/conference/usenixsecurity10/capsicum-practical-capabilities-unix)).

Capsicum's contribution was granularity: rights attach to
scoped resources, not just to verbs. A Capsicum capability is
a verb plus a parameter scope, restrictions can only narrow,
and narrowing is irreversible. This is the shape of Egghead's
scope vocabulary — `net.get{hosts}`, `fs.read{in, paths}`,
`proc.exec{in, cmds, patterns}` — and the rule that scopes
can only narrow.

### Google Macaroons

Birgisson et al., *Macaroons: Cookies with Contextual Caveats
for Decentralized Authorization in the Cloud*, NDSS 2014
([paper](https://research.google/pubs/pub41892/)).

Macaroons are authorization tokens with chained caveats: the
holder can add restrictions without contacting the issuer, and
subset-only delegation is provable without coordination. This
is where Egghead's `agent.grant` attenuation rule comes from:
when one agent grants capabilities to another, the proposed
grants must be a subset of the granter's own. No agent can
hand out authority it does not hold.

## See also

- [Capabilities]({{< ref "capabilities" >}}) is where the
  security-paper lineage actually lives in code.
- [Evals]({{< ref "eval" >}}) is where the MARBLE scoring
  methodology lives.
- [Chat rooms]({{< ref "chat-rooms" >}}) is where the
  graph-topology shape MARBLE's findings argue for is
  implemented.
- [Why Elixir/OTP]({{< ref "why-elixir-otp" >}}) is where the
  MAST conclusion ("failures are architectural") drives the
  runtime choice.
