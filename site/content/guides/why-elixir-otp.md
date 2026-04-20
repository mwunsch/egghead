---
title: Why Elixir/OTP
weight: 50
---

Egghead is built on [Elixir](https://elixir-lang.org), which runs
on the [BEAM](https://en.wikipedia.org/wiki/BEAM_(Erlang_virtual_machine))
— the runtime Ericsson created in the 1980s for telecom switching.
That choice wasn't made for performance. LLM API latency dominates
every hot path in this system; no programming language is going to
move that number. The choice was made because the shape of the
problem — long-lived stateful agents, graceful failure, hot-reload,
shared event streams — is exactly the shape
[OTP](https://en.wikipedia.org/wiki/Open_Telecom_Platform) was
designed around.

This guide explains what the runtime buys Egghead, where it
doesn't help, and what the honest costs are.

## The problem shape

Strip away the LLM specifics and Egghead looks like:

- Many long-lived stateful processes (agents) with independent
  identities, each accumulating per-session context.
- A shared substrate (the record store) that must survive any
  single process's failure.
- Multiple coordinated event streams (chat rooms, PubSub
  broadcasts) where every participant sees every message.
- Graceful degradation under context pressure — when a process
  outgrows itself, its state needs to be serialized and a fresh
  copy brought up.
- An operator running the whole thing on one machine, expecting it
  to keep working through crashes, edits, and network blips.

These are the same constraints telecom equipment runs under. OTP
is a direct fit.

## What OTP gives you

The pieces of OTP Egghead leans on, each mapped to what it does
for the system:

### Processes as units of concurrency

A [BEAM process](https://hexdocs.pm/elixir/processes.html) isn't an
OS thread. It's a lightweight scheduled unit — tens of kilobytes of
heap, microseconds to spawn, millions per node. Each agent is a
[`GenServer`](https://hexdocs.pm/elixir/GenServer.html) (a BEAM
process with a defined message-handling contract). Each chat room
is a GenServer. The record store, the LLM registry, each MCP client
connection — all GenServers.

Why that matters here: agents have independent state and
independent failure modes. When one agent's tool call throws, that
process crashes. The others are unaffected — they're different
processes with different heaps. No shared mutable state to
corrupt, no exception to propagate across contexts.

### Supervision trees

A [supervisor](https://hexdocs.pm/elixir/Supervisor.html) is a
process whose only job is to start, watch, and restart other
processes according to a declared policy. Egghead's supervision
tree is a few dozen lines of code that describes the whole system's
failure behavior:

- If the `Index` process crashes, restart it and the `RecordStore`
  (because `RecordStore` depends on it) — `rest_for_one`.
- If the whole agent layer collapses, restart it without touching
  the record store — isolated sub-tree.
- If an individual agent crashes, restart just that agent with
  fresh state —
  [`DynamicSupervisor`](https://hexdocs.pm/elixir/DynamicSupervisor.html).

The failure policies aren't ad-hoc error handling scattered
through the code. They're a declarative tree. Crash recovery is a
structural primitive.

### "Let it crash"

The [OTP culture](https://erlang.org/download/armstrong_thesis_2003.pdf)
treats crashes as the normal path for unrecoverable errors. Instead
of wrapping every call in defensive `try` blocks, you let the
process die, let the supervisor restart it cleanly, and log the
crash for later review. The state is gone, but it's almost always
state the process was better off without.

This maps directly onto a failure mode specific to LLM agents:
**context degradation**. When an agent's context window fills up
with stale tool output and half-remembered instructions, the
well-trodden fix is to compact — summarize old turns, keep the
summary, drop the originals. But compaction destroys the provenance
of what the agent knew.

Egghead does handoff instead. When context usage crosses a
threshold, the agent serializes itself into a `class: deliberation`
record (its own audit trail) and dies. The supervisor spawns a
fresh copy, which rehydrates from the room's recent transcript and
reads its own prior deliberation as an injected preview.

This isn't a clever innovation. It's literally "let it crash"
applied to context windows. The deliberation record is the OTP
equivalent of a crash dump — except it's a first-class record,
searchable, linkable, readable by the agent's next incarnation.

### Hot code reloading

You can edit an agent record in your editor — change the
disposition, widen capabilities, swap the model — save, and the
next time that agent is addressed, it's running your new code.
No restart. No deploy step. No registration incantation.

The mechanism: the file watcher notices the record change, the
agent supervisor stops the old process, and a new one starts with
the updated record as initialization state. From the user's
perspective, it's instantaneous.

Hot reload is a language feature on most runtimes. On the BEAM it's
a [first-class operational primitive](https://www.erlang.org/doc/system/release_handling.html)
— Ericsson built it because telephone switches can't be taken down
to ship a bugfix. Egghead inherits the consequence: iterating on
an agent feels like editing a document, because that's what it is.

### Distribution, built-in

[Two BEAM nodes on the same network](https://www.erlang.org/doc/system/distributed.html)
can call each other's processes as if they were local.
`GenServer.call({name, node}, msg)` is the same API whether `node`
is the current machine or a machine in a different datacenter.
[Phoenix](https://www.phoenixframework.org)'s
[PubSub](https://hexdocs.pm/phoenix_pubsub/Phoenix.PubSub.html) is
cluster-aware by default — broadcast an event on one node, every
subscribed process on every connected node receives it.

Egghead uses this for the TUI/server split: `egghead serve` runs
the full supervision tree; `egghead` (the TUI) launched elsewhere
discovers that server and connects as a thin client. Same rooms,
same agents, same coordinator — no sync layer, no custom protocol.
The TUI is an attachable frontend, like `tmux attach` for an agent
system.

The work to get there was shockingly small. Distribution wasn't a
product feature that took a quarter; it was a week of
`Node.connect` plumbing plus some routing helpers. The BEAM was
built for this.

## What the runtime is *not* good for

Honest tradeoffs worth naming.

### It's not a security boundary

BEAM process isolation is excellent for fault tolerance: a crash
in one process can't corrupt another. But it was never designed as
a security boundary. A malicious
[NIF](https://www.erlang.org/doc/system/nif.html) (native code
loaded into the BEAM) or a compromised library can read any
process's memory.

Egghead's security model accounts for this explicitly — the
capability system enforces *what* an agent can ask the runtime to
do, and OS-level isolation (hardened containers, microVM-per-tool
for future tool execution) enforces what the resulting code can
reach. BEAM is the first layer; it is not the last.

See the [Capabilities guide]({{< ref "capabilities" >}}) for the
authority model and its explicit limits.

### It's not a numerical runtime

There is no numpy, no CUDA bindings, no competitive ML framework on
the BEAM. This matters for a narrow set of things — local model
hosting, on-device inference, heavy vector math — but for Egghead
it doesn't. The LLMs are remote. The vector work (if we ever do
it) would be shelled out to a NIF or a sidecar.

### It's not fast at CPU-bound work

A single BEAM process is slower than a single Go or Rust goroutine
for tight arithmetic loops. This matters for neither the hot paths
(LLM API latency dominates) nor the warm paths (SQLite queries are
fast enough). Where it would matter — the file parser, the
markdown renderer — we use Erlang primitives that are already
C-optimized under the hood, and it's fine.

### The ecosystem is thin on AI specifics

In 2026, the Python and TypeScript AI library ecosystems are
larger and evolve faster than Elixir's. Egghead built its own
multi-provider LLM registry, streaming clients for Anthropic /
OpenAI / Google APIs, tool-calling normalization across providers,
and an MCP client. None of these were prohibitively hard — they're
a few hundred lines each — but on a Python project they'd have
been a dependency install.

This is a real cost. It's the one worth acknowledging up front: if
your project is LLM-plumbing-first and everything else is
secondary, Python is a lower-friction start. If your project needs
durable stateful processes as a first-class concern, the
dependency-install savings don't pay for the shape you'd have to
invent yourself.

## Why not Go, Rust, Python, or Node

For completeness, the alternatives considered and what each would
have cost.

**Go.** Goroutines give you cheap concurrency, but no supervision
abstractions, no hot reload, no distribution primitives. You'd
build those yourself, probably landing at something that looks
vaguely OTP-shaped with a decade of bugs on the way. Excellent for
stateless services; middling for stateful agent topologies.

**Rust.** Best-in-class fault isolation at the *type* level — the
borrow checker is its own kind of supervisor. But no runtime-level
restart semantics, no hot reload, and [Tokio](https://tokio.rs)
async is great for network-bound work but doesn't give you the
"each agent is a process with its own heap" primitive. A Rust
Egghead would be a different system — arguably tighter but
definitely more code.

**Python.** Fine for LLM clients, which is why most LLM tooling is
in Python today. Async Python
([`asyncio`](https://docs.python.org/3/library/asyncio.html)) can
do concurrency. But the gap between `asyncio` coroutines and BEAM
processes is large: no cheap process spawn, no true isolation, no
supervisor trees, no hot reload in any production-serious form.
Building Egghead in Python would mean either a thick service mesh
([Kubernetes](https://kubernetes.io),
[Celery](https://docs.celeryq.dev), separate process pools) or
accepting that one bug crashes the interpreter.

**Node.** Same concurrency story as Python, plus a runtime that
wasn't designed for long-lived stateful processes. A Node Egghead
would be fighting the grain constantly.

None of these are wrong choices for *other* systems. They're wrong
choices for *this* system because the problem is shaped like the
things BEAM solved forty years ago.

## Design pressure, not raw throughput

The most important thing the BEAM did for Egghead is the least
visible: it applied design pressure. Writing OTP code forces you
to think about process boundaries, failure modes, and topology up
front. "Where does this state live?" isn't a question you can
defer — it's the first question of every module.

For a system where agents are long-lived stateful peers, that
pressure happens to be exactly the pressure the design needs. The
graph topology of chat rooms came out of this pressure. The
handoff-over-compaction pattern came out of it. The distribution
story came out of it. Each of these would have been possible in
another runtime; none would have been as structurally natural.

The counterfactual is worth sitting with: a Python version of
Egghead would likely have landed at dispatcher-based multi-agent
(star topology), bolted-on "memory" as a subordinate subsystem,
and workers that restart via Kubernetes probes. That's a different
system. It would work; it would miss most of the things this
version is trying to demonstrate.

## See also

- [Running a node]({{< ref "running-a-node" >}}) — the operational
  surface the supervision tree exposes
- [Chat rooms]({{< ref "chat-rooms" >}}) — where the graph topology
  and shared transcript patterns live, enabled by Phoenix PubSub
- [Agents]({{< ref "agents" >}}) — the hot-reload, handoff, and
  per-room session shape in concrete terms
- [Research influences]({{< ref "research-influences" >}}) — where
  the "let it crash" philosophy meets the MAST finding that
  multi-agent systems fail architecturally, not at the model level
