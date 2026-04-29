---
title: Why Elixir/OTP
section: Background
weight: 50
summary: What the BEAM and OTP buy when the system is many long-lived stateful processes that need to fail and restart in parts.
---

Almost every other agent framework you have looked at is
written in Python or TypeScript: CrewAI, AutoGen, LangChain,
Mastra, the rest. There are good reasons for that — the LLM
SDKs landed in those ecosystems first and the docs followed —
and Egghead pays a real cost for picking a different language,
in the form of clients and helpers we have had to write
ourselves rather than `pip install` away. So it is worth being
explicit about what we got in exchange.

Egghead is built on Elixir, which runs on the
[BEAM](https://en.wikipedia.org/wiki/BEAM_(Erlang_virtual_machine))
— the runtime Ericsson built in the 1980s for telecom
switching. Performance is not the reason. LLM API latency
dominates every hot path in the system, and no programming
language is going to move that number. The reason is OTP, the
set of conventions and libraries that ship with the BEAM, and
the shape of the problem Egghead is trying to solve.

## The shape of the problem

Strip away the LLM specifics and Egghead looks like:

- Many long-lived stateful processes (one per agent), each
  with independent identity and accumulating per-room session
  state.
- A shared store of records on disk that has to survive any
  individual process crashing.
- Several coordinated event streams (chat rooms, broadcast
  notifications) where every participant subscribes
  independently and the publisher does not know who is
  listening.
- Recovery from per-process failure without restarting the
  whole node.
- Hot reload of configuration: an edit to a record file should
  update the running agent without a deploy, a restart, or a
  message-queue dance.

Those constraints are a near-perfect match for the constraints
telephone switches operate under, which is to say a near-
perfect match for what OTP was built around.

## What the runtime gives Egghead

### Lightweight processes

A BEAM process is not an OS thread. It is a scheduled unit of
tens of kilobytes of heap, with millions per node and
microsecond spawn time. Each agent is one of these processes.
Each chat room is one. The records store, the LLM registry,
each MCP client connection — all processes.

The practical consequence is that every agent has its own
state, its own heap, and its own failure mode. When one
agent's tool call throws an exception, that process crashes;
the others are unaffected because they are different
processes. There is no shared mutable state to corrupt and no
exception to propagate.

### Supervision trees

Failure policy in OTP is not scattered through `try` blocks.
It is a declarative tree describing how processes start, what
they depend on, and what to do when they crash. Egghead's
supervision tree:

```
Egghead.Supervisor (one_for_one)
├── Phoenix.PubSub
├── RecordSupervisor (rest_for_one)
│   ├── Index
│   └── RecordStore
└── Agent.LayerSupervisor (rest_for_one)
    ├── LLM.Registry
    ├── Chat.Coordinator
    └── Agent.Supervisor (DynamicSupervisor)
        ├── index (built-in)
        └── agents/* (one per record)
```

If the records `Index` crashes, the `RecordStore` restarts
with it, because it depends on the index (`rest_for_one`). If
the agent layer collapses entirely, the records store is
unaffected (separate sub-tree). If an individual agent
crashes, the dynamic supervisor restarts just that one agent
with fresh state.

A few dozen lines of declarative configuration describe the
entire failure behavior of the system. That is the shape OTP
was designed for, and writing it in any runtime that does not
have these primitives means inventing them yourself.

### Crash and restart for context overflow

There is a specific failure mode in LLM agents that this
matters for: context degradation. When an agent's context
window fills up with stale tool output and old turns, the
common fix is to compact — summarize old turns, keep the
summary, drop the originals. Compaction destroys the
provenance of what the agent knew, though, and the summary
itself is a lossy artifact you can't audit easily.

Egghead handles this with crash-and-restart instead. When
context usage crosses a threshold, the agent serializes its
session into a `class: deliberation` record (its own
audit trail) and exits. The supervisor restarts a fresh
process; the new process rehydrates from the room's recent
transcript and reads its own prior deliberation as a hand-off
note from the previous incarnation.

This is "let it crash" applied to context windows. The
deliberation record is a durable artifact the next process can
read; the next process is the recovery. Nothing about that
loop is magic — but it is hard to write in a runtime where
crashing is something you avoid rather than something the
supervisor handles for you.

### Hot reload

You edit an agent record in your editor — change the
disposition, widen capabilities, swap the model — save the
file, and the next message addressed to the agent uses the
updated configuration. There is no restart, no deploy, no
re-registration step.

The mechanism is straightforward: the file watcher notices the
change, the agent supervisor stops the old process, and a new
one starts with the updated record as initialization state.
From your perspective it is instantaneous.

Hot reload is a language feature in many runtimes, but on the
BEAM it is a first-class operational primitive. Ericsson built
the capability in because telephone switches cannot be taken
down to ship a bug fix. Egghead inherits the consequence:
iterating on an agent feels like editing a document, because
that is what it is.

### Distribution

Two BEAM nodes on the same network can call each other's
processes as if the processes were local. `Phoenix.PubSub`
broadcasts across the cluster automatically.

Egghead uses this for the TUI/server split: `egghead serve`
runs the full supervision tree, and `egghead` (the TUI)
launched against the same cluster discovers the server and
connects as a thin client. Same rooms, same agents, same
coordinator — no separate sync layer, no custom protocol.
The work to make that real was a week of `Node.connect`
plumbing, not a quarter-long product effort, because the
runtime was built for it.

## What the runtime is not good for

There are honest tradeoffs. None of them changed Egghead's
direction, but it is worth naming them.

The BEAM is not a security boundary. Process isolation prevents
state corruption from crashes, but it does not prevent a
malicious NIF (native code loaded into the BEAM) or a
compromised library from reading another process's memory.
That is why Egghead's [capability model]({{< ref "capabilities" >}})
relies on `sandbox-exec` and `bwrap` for filesystem and
process verbs rather than treating BEAM isolation as the line
of defense.

The BEAM is not a numerical runtime. There is no CUDA, no
fast vector math, no competitive ML framework. None of that
matters for Egghead, because the LLMs are remote and any
heavy local work would be shelled out to a NIF or a sidecar.

The BEAM is not fast at CPU-bound work. A single BEAM process
is slower than a single goroutine for tight arithmetic. None
of Egghead's hot paths are CPU-bound, so this does not matter
either.

The Elixir AI ecosystem is thin compared to Python or
TypeScript. Egghead implements its own multi-provider LLM
registry, streaming clients for each provider, tool-call
normalization across the provider differences, and an MCP
client. These are a few hundred lines each, not impossibly
hard, but in a Python project most of them would have been a
single dependency install.

That last point is the real cost, and it's worth being honest
about it. If a project is LLM-plumbing-first and stateful
coordination is incidental, Python or TypeScript is a
lower-friction start. The trade is worthwhile for Egghead
because the stateful coordination is the system, not the
plumbing — but on a different system with different
priorities, the answer would be different.

## See also

- [Running a node]({{< ref "running-a-node" >}}) describes
  the operational shape the supervision tree exposes.
- [Chat rooms]({{< ref "chat-rooms" >}}) describes what
  `Phoenix.PubSub` and per-room processes actually do.
- [Agents]({{< ref "agents" >}}) describes hot reload,
  handoff, and per-room sessions in concrete terms.
- [Research influences]({{< ref "research-influences" >}})
  cites the multi-agent failure literature whose finding
  ("most failures are architectural, not model-level")
  motivates the supervision-tree investment.
