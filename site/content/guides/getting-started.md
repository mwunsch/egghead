---
title: Getting Started
weight: 5
---

This guide takes you from zero to a working Egghead node —
installed, configured, with a few records in it and a conversation
going with an agent. It's linear; each step sets up the next. At
the end, you'll know where to go for any particular feature you
want to explore.

## What you'll end up with

- Egghead installed and running locally
- A records directory (where your notes and agent definitions live)
- At least one LLM provider configured
- A note you wrote, visible in search
- A conversation with the built-in Index agent
- Optionally: Egghead wired into Claude Code (or another MCP client)

Expect ten to fifteen minutes the first time. Less once you know
the moves.

## Prerequisites

- **macOS (Apple Silicon or Intel) or Linux (x86_64 / arm64).**
  Windows isn't supported yet.
- **An API key for an LLM provider.** Anthropic, OpenAI, Google,
  xAI, Groq, DeepSeek, Mistral, OpenRouter, or a local runner like
  Ollama or LM Studio. Egghead can run without one (record store
  only), but this guide assumes you want the agent layer working.
- **On Linux: `inotify-tools`.** Needed for the file watcher. The
  installer warns if it's missing; `egghead doctor` does too.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/mwunsch/egghead/main/install.sh | sh
```

This drops a self-contained binary at `~/.local/bin/egghead`. Add
that to your `PATH` if it isn't already. Prebuilt binaries are also
available on the [GitHub releases
page](https://github.com/mwunsch/egghead/releases) if you'd rather
fetch them directly.

Verify:

```bash
egghead --help
```

You should see a list of subcommands. If that works, you're set.

## First-run setup

```bash
egghead init
```

Walks a short wizard:

1. **Records directory.** Where your notes will live. Default is
   `~/.egghead`. Pick something else if you have preferences; you
   can change it later in `config.yml`.
2. **LLM provider.** Pick one from the menu and paste your API key
   (or confirm it should read from an environment variable). You
   can add more providers later with `egghead llm add`.
3. **Default model.** After the provider is set up, Egghead fetches
   the available models and lets you pick one.

The wizard writes `~/.config/egghead/config.yml` at the end. That
file is the source of truth for anything you configured — see the
[Configuration guide]({{< ref "configuration" >}}) if you want to
understand what's in it.

Verify:

```bash
egghead doctor
```

Should come back with mostly green. If something complains, the
message will point at the fix.

## Launch the TUI

```bash
egghead
```

You're now in the TUI. Two modes:

- **Records mode** (default) — a Notational Velocity-style records
  browser: instant search on top, arrow-key navigation, Markdown
  preview on the right. Type to search; type a title that doesn't
  match any record to scaffold a new one; hit Enter to open in
  `$EDITOR`.
- **Chat mode** — type `/chat` to enter it. An IRC-style shared
  transcript with agents, slash commands, `@`-mention addressing.

Quit with `Ctrl+Q`. Esc in chat mode takes you back to records mode.

## Write your first record

In records mode, type a title that doesn't match anything (say,
`my first note`) and hit Enter. Your editor opens with a scaffolded
Markdown file. Type something:

```markdown
# My first note

I installed Egghead today. The records directory lives at
~/.egghead. The config file is at ~/.config/egghead/config.yml.

Things I want to explore:
- [[notes/chat-rooms]]
- [[notes/skills]]
```

Save and close the editor. You're back in the TUI; the new record
is in the list. The `[[wikilinks]]` you wrote are live — if you
create a record with id `notes/chat-rooms` later, those links
resolve. Until then they render as unresolved wikilinks (which is
a legitimate state — you're signaling intent to link).

See the [Records guide]({{< ref "records" >}}) for the full
frontmatter surface, wikilink syntax, tags, and classes.

## Your first conversation

From the TUI:

```
/chat
```

You're in the default chat room, looking at an empty transcript.
Type something:

```
Hi. Can you tell me what's in this records store?
```

Hit Enter. The built-in Index agent sees the message, searches
your records, and responds. Because this is an open message (no
`@`-mention), Index decides on its own whether to participate.
With only one agent in your roster, it's going to.

Try a direct mention next:

```
@index what records are tagged with "note"?
```

Or hit it with `/help` to see the slash commands available in chat
mode. The full story lives in the
[Chat rooms guide]({{< ref "chat-rooms" >}}).

When you're done, save the conversation:

```
/save
```

It lands in your store as a record with `class: transcript`.

## Add a specialist agent

Index is good for "what's in the store?" questions. For anything
more specific, you'll want to create your own agent.

Quickest path:

```bash
egghead agents new
```

Walks an interactive flow: name, model, capability picker,
`$EDITOR` for the system prompt. Writes a record at
`agents/<name>.md` in your store. The new agent shows up in chat
rooms immediately — no restart, no re-index.

For the full frontmatter surface and how agents come alive, see
the [Agents guide]({{< ref "agents" >}}). For what `capabilities:`
means and why you should think about it, see
[Capabilities]({{< ref "capabilities" >}}).

## Hook Egghead into Claude Code (optional)

If you use Claude Code and want your records and agents available
as tools, add an MCP entry to `.mcp.json` (in your project, or in
`~/.claude.json` globally):

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

Restart Claude Code. The `egghead_*` tools appear — search, read,
create records, prompt agents, spin up a consultation. Ask Claude
Code "What's in my records about X?" and it reaches for
`egghead_search` on its own.

See the [MCP server guide]({{< ref "mcp" >}}) for the full tool
surface and how to wire the HTTP transport instead.

## Running in the background

For a persistent node (web UI, HTTP MCP endpoint, long-running
agent state), use `egghead serve`:

```bash
egghead serve
```

Opens on `http://localhost:4000`. LiveView records browser, chat
rooms, MCP at `/mcp`, all on one port. Bound to loopback by
default.

For serious use — systemd, reverse proxies, exposing externally —
the [Running a node guide]({{< ref "running-a-node" >}}) covers
the operational surface.

## Quick reference

The commands worth knowing:

```bash
egghead                  # Launch TUI
egghead init             # First-run wizard
egghead serve            # Web + MCP HTTP server
egghead mcp              # MCP stdio (for editor integration)
egghead doctor           # Check setup
egghead agents list      # Running agents, with token usage
egghead agents new       # Create an agent interactively
egghead skills list      # Available skills
egghead config path      # Show resolved config path
egghead llm list         # Configured providers
egghead logs             # Tail the log file
```

Every command accepts `--help` for its own flag surface.

## Where to go next

Depending on what you want to do:

- **Work with records** — [Records]({{< ref "records" >}}),
  [Record classes]({{< ref "record-classes" >}}).
- **Collaborate with agents** — [Chat
  rooms]({{< ref "chat-rooms" >}}),
  [Agents]({{< ref "agents" >}}), [Skills]({{< ref "skills" >}}).
- **Lock down what agents can do** —
  [Capabilities]({{< ref "capabilities" >}}).
- **Integrate with editors or external clients** —
  [MCP server]({{< ref "mcp" >}}),
  [Consultation]({{< ref "consultation" >}}).
- **Run a persistent node** —
  [Running a node]({{< ref "running-a-node" >}}),
  [Configuration]({{< ref "configuration" >}}).

The guides cross-link; pick a thread and pull.

## If something breaks

- **`egghead doctor`** is the first move. It checks config,
  records directory, providers, and common setup problems.
- **`egghead logs`** tails the log file. Errors from the agent
  loop and the supervision tree land here.
- **GitHub issues:** [mwunsch/egghead/issues](https://github.com/mwunsch/egghead/issues).

Most first-run problems are one of: missing API key env var,
`inotify-tools` absent on Linux, or a typo in `config.yml`. Doctor
catches all three.
