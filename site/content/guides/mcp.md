---
title: MCP server
weight: 30
---

Egghead exposes its entire tool surface — records, search, agents,
consultation — over the Model Context Protocol. Point Claude Code at
it, point a custom client at it, or call it over HTTP from anywhere
on your network. One handler, two transports, fifteen tools.

This guide covers the tool surface, how to wire both transports,
and the security posture you should assume when running MCP inside
or outside loopback.

## The two transports

Egghead speaks MCP over both standard MCP transports:

- **Stdio** — `egghead mcp` runs a JSON-RPC server on stdin/stdout.
  This is how editor integrations talk to it. Low-latency, local-only,
  no network exposure. One Egghead-node process per client.
- **HTTP** — `POST /mcp` on the web server. Mounted inside the same
  Phoenix endpoint as the UI, on the same port. Shared node state,
  so multiple clients all see the same record store and agents.

Both transports route through the same handler. Whatever works on
one works on the other. Pick based on how the client connects.

## The tool surface

Fifteen tools, all prefixed `egghead_`. They split into four groups.

### Records — eight tools

| Tool                  | What it does                                                 |
|-----------------------|--------------------------------------------------------------|
| `egghead_search`      | FTS5 search over titles + bodies; returns ranked results    |
| `egghead_get`         | Read a record by id — body, metadata, tags, links, outline |
| `egghead_list`        | List records, optionally filtered by tag                    |
| `egghead_create`      | Create a new record; auto-ids if you don't specify one      |
| `egghead_update`      | Update a record by merging fields; omitted fields preserve  |
| `egghead_find_links`  | Forward graph traversal from a record at specified depth    |
| `egghead_backlinks`   | Reverse graph — who links here?                             |
| `egghead_recent`      | Recently updated/created, sorted                             |

These are the workhorses — the same surface the
[Records guide]({{< ref "records" >}}) covers, just reached for
over MCP. If the MCP client is an editor or a knowledge tool,
these are what it actually uses.

### Agents — four tools

| Tool               | What it does                                                    |
|--------------------|-----------------------------------------------------------------|
| `egghead_agents`   | List running agents with model, capabilities, token usage       |
| `egghead_prompt`   | 1:1 prompt to a named agent (ephemeral, no room)                |
| `egghead_handoff`  | Summarize + clear an agent's session, optionally continue        |
| `egghead_save`     | Extract insights from an agent's session as durable records     |

### Collaboration — one tool

| Tool              | What it does                                                 |
|-------------------|--------------------------------------------------------------|
| `egghead_consult` | Spin an ephemeral room, ask a question, return aggregated answers, auto-save, stop |

`consult` is usually the most interesting tool for external clients
— it gives you a multi-agent answer without forcing you to think
about rooms. See the [Consultation guide]({{< ref "consultation" >}}).

### Configuration — two tools

| Tool                | What it does                                      |
|---------------------|---------------------------------------------------|
| `egghead_providers` | List configured LLM providers and auth status    |
| `egghead_models`    | List available models across configured providers |

## Wiring it into Claude Code (stdio)

Claude Code reads `.mcp.json` in your project (or `~/.claude.json`
globally). Add an entry:

```json
{
  "mcpServers": {
    "egghead": {
      "command": "egghead",
      "args": ["mcp"]
    }
  }
}
```

Restart Claude Code, and the `egghead_*` tools appear. Ask Claude
"What's in my records about rate limiting?" and it will reach for
`egghead_search` on its own.

If you're running a dev build, use the project-local path:

```json
{
  "mcpServers": {
    "egghead": {
      "command": "/path/to/egghead/bin/egghead",
      "args": ["mcp"]
    }
  }
}
```

## Wiring it over HTTP

Start the server:

```bash
egghead serve
```

Point a client at `http://localhost:4000/mcp`:

```json
{
  "mcpServers": {
    "egghead-http": {
      "transport": "http",
      "url": "http://localhost:4000/mcp"
    }
  }
}
```

Same tool surface, different wire. The HTTP transport is the right
choice when the client is on a different machine, when multiple
clients need to share state, or when you want to go through a
reverse proxy for TLS and auth.

See the [Running a node guide]({{< ref "running-a-node" >}}) for
what to do before you expose the port outside loopback.

## Tool parameters

Parameters match the shape you'd expect. A few examples:

```json
{"name": "egghead_search", "arguments": {"query": "postgres vacuum", "limit": 10}}
{"name": "egghead_get", "arguments": {"id": "notes/postgres-vacuum"}}
{"name": "egghead_create", "arguments": {
  "id": "inbox/2026-04-19-standup",
  "title": "Standup notes",
  "class": "inbox",
  "tags": ["inbox", "meeting"],
  "body": "## Action items\n- ..."
}}
{"name": "egghead_consult", "arguments": {
  "question": "What's the failure mode if we drop autovacuum?",
  "timeout": 120
}}
```

The MCP tool descriptions (which the LLM sees when deciding what to
call) list each tool's fields. `egghead mcp` or the HTTP endpoint
both serve the live schema — a client fetching `tools/list` gets the
authoritative surface.

## Security posture

Worth being explicit, because MCP and capabilities live in
different layers and it's easy to assume they compose.

**MCP tools operate with node authority.** There is no per-caller
capability check at the MCP boundary. A client calling
`egghead_create` can create any record. A client calling
`egghead_prompt` can prompt any agent. The full tool surface is
available to anything that can talk to the transport.

**Capabilities apply to agents, not MCP callers.** When you prompt
an agent via `egghead_prompt` or consult via `egghead_consult`, the
agent itself runs under its declared capabilities — so the agent
can't do things it's not allowed to do, even at the request of an
MCP caller. But that caller can always ask a differently-configured
agent instead.

This is deliberate. MCP is the trusted-operator interface. The
authority gradient is: MCP caller (trusted) → agent (capability-
gated) → tool execution. If the MCP transport is reachable, you are
trusting whoever can reach it.

In practice this means two things:

- **Keep stdio local.** It's a subprocess of your editor. Don't
  pipe it across SSH for a client you don't control.
- **Guard HTTP.** Bind to `127.0.0.1` (the default) and only expose
  via a reverse proxy that does authentication. Never bind to
  `0.0.0.0` without a firewall and auth in front. An unauthenticated
  public Egghead HTTP endpoint is an invitation to write anywhere
  in your record store.

If you need a more fine-grained MCP-caller identity model in the
future, the right place for that enforcement is the reverse-proxy
auth layer plus per-path routing — not inside Egghead. Keep the
local interface simple; move the perimeter outward.

## What the tools don't do

- **`egghead_create` and `egghead_update` don't enforce capability
  checks.** They're MCP tools; same rule as the section above.
  Agents invoking the equivalent tools through their own tool-use
  loop *do* get capability-checked, because the agent is the caller.
- **MCP doesn't stream chat.** `egghead_prompt` and
  `egghead_consult` are request/response. For streaming transcripts
  or live room participation, drive the room from code
  (`Egghead.watch/1`) or the web UI. MCP is the one-shot surface.
- **There's no tool for live rooms yet.** Rooms persist across MCP
  calls, but the MCP surface doesn't yet expose `list_rooms`, `join`,
  or `chat`. Use consult for swarm questions and prompt for direct
  agent queries.

## See also

- [Consultation]({{< ref "consultation" >}}) — the pattern most
  external clients end up using
- [Running a node]({{< ref "running-a-node" >}}) — network exposure,
  reverse proxies, process management
- [Capabilities]({{< ref "capabilities" >}}) — the authority model
  for agents, which applies whenever an agent is the one acting on
  an MCP caller's behalf
