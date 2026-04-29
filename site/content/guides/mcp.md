---
title: MCP server
section: Integrations
weight: 30
summary: Egghead's record and agent surface exposed as MCP tools, over stdio for editor integrations or HTTP for remote callers.
---

Egghead exposes fifteen tools over the Model Context Protocol.
There are two transports — stdio and HTTP — and they share one
handler. Whatever you can do with one transport, you can do
with the other; the choice is about how the calling client
connects.

## Choosing a transport

| Transport | Command         | Endpoint                          | Use when |
|-----------|-----------------|-----------------------------------|----------|
| Stdio     | `egghead mcp`   | JSON-RPC over stdin and stdout    | An editor or local tool spawns Egghead as a subprocess. |
| HTTP      | `egghead serve` | `POST /mcp` on the web server     | Multiple clients share one Egghead node, or a client connects from another machine through a reverse proxy. |

Stdio is what Claude Code and most editor integrations use. The
client launches `egghead mcp` as a subprocess, talks to it over
stdin and stdout, and tears it down when the editor session
ends. There is one Egghead node per editor.

HTTP is what you use when a long-lived `egghead serve` process
already exists and you want one or more clients to share its
state. The same web server that hosts the records browser also
hosts the MCP endpoint at `/mcp`, so there is no separate
service to manage.

## Tools

All tool names are namespaced `egghead_`.

### Records

| Tool                  | Purpose |
|-----------------------|---------|
| `egghead_search`      | FTS5 search over titles and bodies; ranked. |
| `egghead_get`         | Read a record by id. |
| `egghead_list`        | List records, optionally filtered by tag. |
| `egghead_create`      | Create a record; auto-id if you don't specify one. |
| `egghead_update`      | Merge fields into an existing record. |
| `egghead_find_links`  | Forward link traversal to the requested depth. |
| `egghead_backlinks`   | Reverse link traversal — what points here? |
| `egghead_recent`      | Recently created or updated records. |

### Agents

| Tool              | Purpose |
|-------------------|---------|
| `egghead_agents`  | List running agents with usage. |
| `egghead_prompt`  | One-shot prompt to a single agent (no room). |
| `egghead_handoff` | Summarize and clear an agent's session. |
| `egghead_save`    | Distill an agent's session into a deliberation record. |

### Consultation

| Tool              | Purpose |
|-------------------|---------|
| `egghead_consult` | Spin up an ephemeral room, ask a question, return aggregated answers, save the transcript. |

`egghead_consult` is usually the most useful tool for an
external client that wants multi-agent input without managing
rooms. See [Consultation]({{< ref "consultation" >}}).

### Configuration

| Tool                | Purpose |
|---------------------|---------|
| `egghead_providers` | List configured LLM providers and their auth status. |
| `egghead_models`    | List models available across the configured providers. |

## Wiring stdio into Claude Code

Add an MCP server entry to `.mcp.json` in your project, or to
`~/.claude.json` for a global hook-up:

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

Restart Claude Code. The `egghead_*` tools appear in the tool
list, and Claude can reach for them on its own. Asking Claude
"What's in my records about rate limiting?" causes it to call
`egghead_search` without further prompting.

If you are running a development build, point at the absolute
path:

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

## Wiring HTTP

Start the server:

```bash
egghead serve
```

The default bind is `127.0.0.1:4000`, so the HTTP endpoint is
reachable at `http://localhost:4000/mcp` from the same machine.
Point a client at it:

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

The HTTP transport is the right choice when the client is on
another machine, when several clients should see the same
records and the same agents, or when you want to put TLS and
authentication in front of Egghead. For exposing the server
beyond loopback, see
[Running a node]({{< ref "running-a-node" >}}).

## Example calls

```json
{"name": "egghead_search", "arguments": {"query": "postgres vacuum", "limit": 10}}
```

```json
{"name": "egghead_create", "arguments": {
  "id": "inbox/2026-04-19-standup",
  "class": "inbox",
  "tags": ["meeting"],
  "body": "## Action items\n- ..."
}}
```

```json
{"name": "egghead_consult", "arguments": {
  "question": "What's the failure mode if we disable autovacuum?",
  "timeout": 120
}}
```

The authoritative tool schemas — including each tool's full
parameter list and validation rules — are served by the
`tools/list` MCP method on either transport.

## Security posture

This is the section that bites people, so it is worth being
explicit. MCP tools in Egghead operate with full node
authority. There is no per-caller capability check at the MCP
boundary. A client calling `egghead_create` can write any
record. A client calling `egghead_prompt` can address any
agent. The full tool surface is available to anything that can
reach the transport.

Capabilities apply to *agents*, not to MCP callers. When you
prompt an agent through `egghead_prompt`, the agent's actions
are still constrained by its declared capabilities — but
nothing stops the MCP client from picking a different agent
with broader authority and prompting that one instead.

Two practical consequences follow.

For stdio, treat the transport as a subprocess of the calling
editor. Don't tunnel `egghead mcp` over SSH for a client you
don't control, and don't share a stdio pipe across users.

For HTTP, keep the bind on `127.0.0.1` (the default) and put
authentication in front of any externally reachable surface.
Running an unauthenticated public Egghead HTTP endpoint is
equivalent to publishing read/write access to your entire
record store; anyone who can reach the URL can read every
note, edit any record, and prompt any agent. The right place
for per-caller identity is in the reverse proxy, not inside
Egghead.

## Limitations

There is no streaming chat over MCP yet. `egghead_prompt` and
`egghead_consult` are request/response. If you want to follow
a transcript live, drive the room from code with
`Egghead.watch/1` or use the web UI.

There are no room-management tools yet. Rooms persist across
MCP calls, but the surface does not yet expose `list_rooms`,
`join`, or `chat`. Use `egghead_consult` for a one-shot
multi-agent question and `egghead_prompt` for a direct
one-on-one query.

## See also

- [Consultation]({{< ref "consultation" >}}) covers the
  pattern most external MCP callers end up using.
- [Running a node]({{< ref "running-a-node" >}}) covers
  network exposure and reverse-proxy setup.
- [Capabilities]({{< ref "capabilities" >}}) covers what an
  agent invoked through MCP is allowed to do.
