---
title: Guides
---

Narrative documentation for using and extending Egghead. Pick a
thread and pull — the guides cross-link, so one will lead you to
the next.

## Start here

- [Getting started]({{< ref "getting-started" >}}) — install,
  first record, first conversation, in about ten minutes.

## The substrate

Records are the atomic unit; everything else — agents, rooms,
transcripts, deliberations — is a record with a class.

- [Records]({{< ref "records" >}}) — markdown files,
  `[[wikilinks]]`, frontmatter, search.
- [Record classes]({{< ref "record-classes" >}}) — `durable`,
  `inbox`, `agent`, `transcript`, `deliberation`: what they mean
  and when to use them.

## The participants

- [Chat rooms]({{< ref "chat-rooms" >}}) — the graph-topology,
  shared-transcript coordination model. `@mentions`, `/pass`,
  `@everyone`, `@jam`, handoff, save/resume.
- [Agents]({{< ref "agents" >}}) — agent records: identity, model,
  disposition, capabilities. How they come alive and where they
  live in the supervision tree.
- [Skills]({{< ref "skills" >}}) — packaged capability bundles
  that give an agent a new trade.

## The authority model

- [Capabilities]({{< ref "capabilities" >}}) — the
  `resource.verb`-scoped grant system that decides what any agent
  is allowed to do. Least privilege, separation of duties,
  attenuation-only delegation — at the infrastructure level, not
  vibes.

## External integration

- [MCP server]({{< ref "mcp" >}}) — expose Egghead's tool surface
  to editors and other clients, over stdio or HTTP.
- [Consultation]({{< ref "consultation" >}}) — the fire-and-forget
  "ask the room a question and get aggregated answers" shape,
  ideal for MCP callers.

## Operations

- [Configuration]({{< ref "configuration" >}}) — `config.yml`,
  provider setup, XDG paths, `$EGGHEAD_CONFIG`.
- [Running a node]({{< ref "running-a-node" >}}) — `egghead serve`
  as a long-lived process: systemd, reverse proxies, exposure.

## Knowing it works

- [Evals]({{< ref "eval" >}}) — `egghead eval` as a fifth
  interface, peer to the TUI, CLI, web, and MCP. Score your
  roster against a task, with milestone-based KPIs ported from
  MultiAgentBench.

## Why it looks like this

- [Why Elixir/OTP]({{< ref "why-elixir-otp" >}}) — what the BEAM
  buys when agents are long-lived stateful peers that fail in
  parts.
- [Research influences]({{< ref "research-influences" >}}) — the
  PKM lineage (Zettelkasten, Second Brain, Evergreen notes), the
  2023–2025 multi-agent research (graph topology, failure
  taxonomy, conformity, division of labor), and the capability
  systems (pledge, Capsicum, Macaroons) that shape the design.

## If you're reading on a schedule

- **First thirty minutes.** Getting started → Records → Chat
  rooms. You'll have a working node and a conversation.
- **The afternoon.** Agents → Capabilities → Skills → MCP. You'll
  have a roster wired into your editor.
- **The weekend.** Evals → Research influences → Why Elixir/OTP.
  You'll know what you're actually betting on.
