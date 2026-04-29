---
title: Getting started
section: Getting started
weight: 5
summary: Install Egghead, configure an LLM provider, write a record, hold a conversation. About ten minutes.
---

This guide takes you from nothing to a running Egghead node with
one record in your store and one conversation against an agent.
Each step depends on the one before it, so work through them in
order. By the end you will know which other guide to read next
for whatever you want to do.

## Prerequisites

You need a Mac (Apple Silicon or Intel) or a Linux machine on
x86_64 or arm64. Windows is not supported. You also need an API
key for at least one LLM provider, since the agent layer cannot
do anything without one. Egghead supports Anthropic, OpenAI,
Google, xAI, Groq, DeepSeek, Mistral, and OpenRouter, and it can
talk to local runners like Ollama or LM Studio. The record store
itself works with no provider configured, but every feature that
calls a model returns an error in that mode.

On Linux, install `inotify-tools` and `bubblewrap` from your
package manager before continuing. Egghead uses the first to
notice when you edit a record and the second to sandbox the file
and process operations agents are allowed to perform. The
installer warns if either is missing, and `egghead doctor`
re-checks at any time.

## Install

Run the install script:

```bash
curl -fsSL https://raw.githubusercontent.com/mwunsch/egghead/main/install.sh | sh
```

The script downloads a self-contained binary to
`~/.local/bin/egghead`. If that directory is not on your `PATH`
yet, add it. Prebuilt binaries are also published on the
[GitHub releases page](https://github.com/mwunsch/egghead/releases)
if you would rather fetch them by hand.

Confirm the install worked by asking for help:

```bash
egghead --help
```

You should see a list of subcommands.

## First-run setup

```bash
egghead init
```

The wizard asks three questions and writes
`~/.config/egghead/config.yml` at the end. First, it asks where
your records should live; the default is `~/.egghead`, and you
can change it later by editing the config file. Second, it asks
which LLM provider to set up and where to find the API key; you
can either paste the key directly or point at an environment
variable. Third, it fetches the available models for that
provider and lets you pick one as the default.

You can re-run `egghead init` at any time, or you can edit
`config.yml` by hand. The full schema lives in
[Configuration]({{< ref "configuration" >}}).

Then verify the install picked up everything correctly:

```bash
egghead doctor
```

`doctor` reports on the config file, the records directory, each
configured provider, and any platform-specific dependencies. If
it finds a problem, the message tells you how to fix it.

## Launch the TUI

```bash
egghead
```

The TUI opens in records mode, which is a Notational
Velocity-style records browser: instant search at the top,
arrow-key navigation, a preview pane on the right. Type a title
that does not match an existing record and press Enter; Egghead
opens `$EDITOR` with a scaffolded Markdown file for you to fill
in.

To switch to chat mode, type `/chat`. Chat mode is an IRC-style
shared transcript that includes you and one or more agents.
You send messages by typing and pressing Enter; you address a
specific agent with `@<agent-id>`; you run commands like `/save`
and `/handoff` from the same prompt. `Esc` returns to records
mode, and `Ctrl+Q` quits the TUI altogether.

## Write your first record

Stay in records mode and type a title that does not match
anything in your store, like `my first note`. Press Enter, and
your editor opens a scaffolded Markdown file. Write a sentence,
save, and quit the editor. The new record is in the list
immediately and is searchable as soon as you start typing in the
search bar.

The record format — frontmatter, wikilinks, classes, the lot —
is documented in [Records]({{< ref "records" >}}). Read that
guide next if you want to understand what `[[wikilinks]]` resolve
to and how `class:` changes the system's behavior.

## Hold a conversation

Type `/chat` to enter chat mode. You are now in the default chat
room, looking at an empty transcript. Send a message:

```
Hi. What's in this records store?
```

The built-in `index` agent ships with every install. It holds
read-only access to your records and exists so that a fresh
install always has someone to talk to. With only `index` in the
roster, every open message activates it. Try addressing it
directly, too:

```
@index list every record tagged "note"
```

When you are done, save the conversation:

```
/save
```

The transcript becomes a record in your store with
`class: transcript`, which means you can search it, link to it,
and rejoin it later by typing `/join chat/<id>`. The full set of
slash commands is documented in
[Chat rooms]({{< ref "chat-rooms" >}}).

## Add an agent

`index` is intentionally limited; for anything beyond looking at
the store, you write your own agents. The fastest path is the
interactive wizard:

```bash
egghead agents new
```

The wizard walks you through naming the agent, picking a model,
selecting capabilities (sorted from low risk to high), and
writing the system prompt in `$EDITOR`. It saves the result as
`agents/<slug>.md` in your records directory. The agent is live
in chat rooms immediately, with no restart and no reindex
step, because the file watcher noticed the new record and
started a process for it.

The full anatomy of an agent record is in
[Agents]({{< ref "agents" >}}), and the full meaning of the
`capabilities:` field is in
[Capabilities]({{< ref "capabilities" >}}). If you are coming
from a framework where agents are Python classes or YAML role
definitions, the thing to know is that an Egghead agent is a
file. Editing the file updates the running agent on the next
turn.

## Wire Egghead into Claude Code

If you use Claude Code, you can expose your records and agents
to it as MCP tools. Add an entry to `.mcp.json` in your project
or to `~/.claude.json` for a global hook-up:

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

Restart Claude Code. The fifteen `egghead_*` tools appear in
the tool list, and Claude can now search your records, prompt
your agents, and ask the room for input the same way it uses
its other MCP servers. The tool surface and the HTTP transport
alternative are documented in [MCP server]({{< ref "mcp" >}}).

## Run a long-lived node

If you would rather have Egghead running in the background with
a web UI and a network-reachable MCP endpoint, use the server
mode:

```bash
egghead serve
```

The web server starts on `http://localhost:4000`, listening only
on the loopback interface by default. From that one port you get
a records browser, the chat rooms in a windowed UI, and the MCP
HTTP endpoint at `/mcp`. For the full operational story —
running under `systemd` or `launchd`, putting a reverse proxy in
front, exposing the node beyond your laptop — read
[Running a node]({{< ref "running-a-node" >}}).

## Command reference

Worth knowing as you explore:

```text
egghead                  Launch the TUI.
egghead init             First-run wizard.
egghead serve            Web UI and MCP HTTP server.
egghead mcp              MCP stdio server, for editor integrations.
egghead doctor           Diagnose configuration and dependencies.
egghead agents list      Show running agents and their token usage.
egghead agents new       Interactive agent creation.
egghead skills list      Show available skills.
egghead config path      Print the resolved configuration path.
egghead llm list         Show configured LLM providers.
egghead logs             Tail the application log.
```

Every subcommand accepts `--help` for a flag listing.

## When something breaks

Run `egghead doctor` first. It catches the common first-run
failures: a missing API key environment variable, the absence
of `inotify-tools` on Linux, a malformed `config.yml`. The
message tells you exactly what is wrong and how to fix it.

If `doctor` looks clean but something is still off, tail the
log with `egghead logs`. Errors from the supervision tree and
from the agent loop land there.

If you think you have found a bug, open an issue at
[mwunsch/egghead/issues](https://github.com/mwunsch/egghead/issues).
