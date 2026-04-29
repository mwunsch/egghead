---
title: Tools
section: Capabilities
weight: 20
summary: The catalog an agent picks from — built-in tools, MCP servers, and the two-stage gate that decides which tools each agent actually sees.
---

A tool is a function the model can call. Egghead ships a built-in
set — the record-store tools, web fetch, filesystem, subprocess —
and lets you extend the catalog by registering Model Context
Protocol (MCP) servers. The two sources merge into one menu, and
which entries an agent sees on that menu depends on the
capabilities the agent holds.

That last part is the place Egghead diverges from most harnesses.
In Claude Code, a tool is offered to the model and the user is
asked at call time whether to allow it. In CrewAI, a tool is
attached directly to the agent and runs when the agent decides to
call it. Egghead splits the choice in two: the *menu* is
determined by the agent's capabilities up front (so the model
never sees a tool it would not be allowed to call), and each
*call* is re-checked against the same capability list before the
tool actually runs. The full grant grammar lives in
[Capabilities]({{< ref "capabilities" >}}); this guide is about
the menu.

## The two-stage gate

Egghead checks an agent's authority twice on every tool, at two
different points.

The first check is at *offering time*: when Egghead assembles the
tool list it sends to the model on each turn, it filters out any
tool the agent could not call. A tool with `offers_on: fs.read`
is not in the list for an agent that does not hold `fs.read`. An
MCP server's tools are absent for agents whose grants do not
cover that server's `requires:` set. The model never even hears
about the tool, so it cannot try and fail.

The second check is at *dispatch time*: when the model decides to
invoke a tool, the tool's input is resolved into one or more
concrete capability requests, and every request must pass
`Capability.check`. This is where scopes are enforced. An agent
that holds `net.get{hosts: ["api.github.com"]}` sees `web_fetch`
in its menu, but a `web_fetch` call to `evil.example.com` returns
a capability denial rather than a network round trip.

Two stages, one capability list. The reason for both is that
offering-time filtering keeps the model honest and dispatch-time
filtering keeps the operator honest: the agent does not get to
hallucinate authority by calling a hidden tool, and a stale or
overbroad scope cannot leak through if the verbs match.

## Built-in tools

Every Egghead install ships these, and the offering-time filter
shows each one to agents who hold the relevant verb.

### Record-store tools

| Tool              | Verb            | Purpose |
|-------------------|-----------------|---------|
| `search_records`  | `records.read`  | FTS5 search across titles and bodies. |
| `get_record`      | `records.read`  | Read frontmatter and a body preview for a single record. |
| `get_record_body` | `records.read`  | Read the full body when the preview was not enough. |
| `list_records`    | `records.read`  | List records, optionally filtered by tag. |
| `find_links`      | `records.read`  | Forward link traversal from a starting record. |
| `find_backlinks`  | `records.read`  | Reverse traversal — who links to this? |
| `recent_records`  | `records.read`  | Recently created or updated records. |
| `create_record`   | `records.create` / `agent.create` | Write a new record. Routing depends on `class:`; agent records require `agent.create`. |
| `update_record`   | `records.update` / `agent.update` / `agent.grant` | Merge new fields. Capability or sandbox edits on agent records require `agent.grant`. |
| `delete_record`   | `records.delete` / `agent.delete` | Move a record to `.trash/`. For agent records this stops the agent. |

The default capability set for a fresh agent is `[records.read]`,
which is exactly the seven read-only tools above — enough to be
useful in a room without being able to mutate anything.

### Network, filesystem, subprocess

| Tool        | Verb        | Purpose |
|-------------|-------------|---------|
| `web_fetch` | `net.get`, `net.post`, `net.put`, `net.delete` | HTTP request. HTML responses are stripped to readable text by default. |
| `fs_read`   | `fs.read`   | Read a file outside the record store. |
| `fs_grep`   | `fs.read`   | ripgrep-style search across a directory. |
| `fs_write`  | `fs.write`  | Write or overwrite a file outside the record store. |
| `proc_exec` | `proc.exec` | Spawn a subprocess with argv — no shell. |
| `proc_eval` | `proc.eval` | Evaluate a shell pipeline through `bash -c`. |

The filesystem and subprocess verbs go through the kernel
sandbox in addition to the matcher; the network verb does not.
The reasoning, and the macOS / Linux specifics, are in
[Capabilities]({{< ref "capabilities" >}}).

## MCP servers

The Model Context Protocol is the way the rest of the ecosystem
ships tools, and Egghead is an MCP client as well as a server.
[MCP server]({{< ref "mcp" >}}) covers the surface Egghead
*exposes*; this section covers the surface Egghead *consumes*.

When you register an MCP server, every tool the server reports
becomes a candidate for the menu. Tool names are prefixed
`mcp__<server>__<tool>` when sent to the model, so an `exa`
server's `web_search` tool appears as `mcp__exa__web_search` in
the transcript.

The conceptual difference from `.mcp.json` in Claude Code is what
gets declared at registration time. In `.mcp.json` you write the
launch command; the tools the server reports are then trusted to
do whatever they want with whatever ambient authority the host
grants. In Egghead's config, each server entry also carries a
`requires:` list — the *capabilities the agent takes on* by
calling that server's tools. The launch command is an
orchestrator detail, authorized once at install time; the
`requires:` set is the security boundary, enforced on every call.

```yaml
mcp_servers:
  - name: exa
    transport: stdio
    command: "npx -y exa-mcp-server"
    env:
      EXA_API_KEY: "{env:EXA_API_KEY}"
    requires:
      - net.get:
          hosts: ["api.exa.ai"]
```

A server's tools are offered to an agent only when the agent's
grants are a superset of the server's `requires:`. An agent that
holds `net.get{hosts: ["*"]}` sees the `exa` tools; an agent that
holds `net.get{hosts: ["docs.python.org"]}` does not. There is no
prompt and no warning — the tools are simply absent from that
agent's menu.

### Adding a server

The CLI has a small curated registry of common servers (Exa,
GitHub, Brave, Slack, the local filesystem server, and Egghead
itself, so one node can mount another's record store).

```bash
egghead tools mcp available           # what's in the curated registry
egghead tools mcp add exa             # install from the registry
```

For anything not in the registry, declare the transport
explicitly. The CLI walks you through the capability bundle the
server should require, then writes the entry to your
`config.yml`.

```bash
egghead tools mcp add weather --stdio "mcp-weather"
egghead tools mcp add api    --http  "https://api.example.com/mcp"
```

The wizard is the place to be deliberate. A server that genuinely
only fetches one host should require exactly
`net.get{hosts: ["that-host"]}`, not `net.get{hosts: ["*"]}` —
the narrower the `requires:`, the easier it is to grant safely
later. Skill authoring guidance has a longer take on the same
principle in [Skills]({{< ref "skills" >}}).

### Removing or inspecting

```bash
egghead tools mcp list                # configured servers, with status
egghead tools mcp show exa            # config, tools, eligible agents
egghead tools mcp who exa             # which agents are eligible (one per line)
egghead tools mcp remove exa          # take it out of config and stop the process
```

`show` is the one to know. It prints the server's `requires:`,
the tools it advertises, and the list of agents whose grants
cover the requirement — useful when a tool you expected to be
visible to an agent is mysteriously missing.

## Inspecting an agent's menu

The most common question while authoring an agent is "what can
this agent actually call?" The CLI answers it directly:

```bash
egghead tools list --agent scout
```

Tools the agent can use are marked with a green ●; tools filtered
out by the offering-time gate are marked with a red ○ and dimmed.
The output covers both built-in and MCP sources, so a missing
green dot tells you which capability to grant. The companion
command,

```bash
egghead tools mcp who exa
```

inverts the question: instead of "what can this agent call?", it
asks "who can call this server?". Both end up in the same place;
which one is faster depends on whether you are debugging an agent
or debugging a server.

## CLI reference

```bash
egghead tools list                    # full catalog, by source
egghead tools list --agent <id>       # filtered to one agent's eligible set
egghead tools list --source mcp       # only MCP, only local, or all (default)

egghead tools mcp list                # configured servers
egghead tools mcp available           # curated registry of known servers
egghead tools mcp show <name>
egghead tools mcp who <name>
egghead tools mcp add <name> [--stdio <cmd> | --http <url>]
egghead tools mcp remove <name>
```

`egghead tools` with no arguments is a shorthand for `tools list`.

## See also

- [Capabilities]({{< ref "capabilities" >}}) covers the verbs
  themselves, the scope grammar, and the OS sandbox that backs
  the filesystem and subprocess verbs.
- [Skills]({{< ref "skills" >}}) covers the layer above tools:
  packaged instruction sets that declare which tools they assume
  and only resolve for agents whose menus already include them.
- [MCP server]({{< ref "mcp" >}}) covers the inverse direction —
  Egghead's record and agent surface exposed as MCP tools to
  external clients.
- [Agents]({{< ref "agents" >}}) covers where the capability list
  lives and how editing the agent record changes the menu on the
  next turn.
