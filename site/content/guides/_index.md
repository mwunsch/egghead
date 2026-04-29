---
title: Guides
summary: Documentation for installing, configuring, and operating Egghead.
---

These guides cover the user-visible surface of Egghead: the CLI,
the TUI, the web interface, and the MCP server. They assume you
have a working shell, an editor, and an API key for at least one
LLM provider.

If you have already used CrewAI, Paperclip, or OpenClaw, a few of
Egghead's design choices will look unfamiliar at first, and that
is on purpose. Records live as plain Markdown files in a
directory you choose, not inside an internal database. Agents are
defined by those Markdown files, not by Python classes or YAML
roles. Capabilities are written into an agent's frontmatter ahead
of time, not approved through "Allow once" prompts at runtime.
Most chat in Egghead happens in a shared transcript that every
participant reads, not through a dispatcher that routes each turn.
The rest of the documentation explains how each of those choices
works in practice and what it costs you when it doesn't fit.

If you are new to the system, read **Getting started** first; it
gets you to a running node with one agent in about ten minutes.
After that, the order in the left rail follows the order things
become useful: records and record classes describe what you
store; the agents section describes what runs against that store;
the capabilities section describes what those agents are allowed
to do; and the rest of the rail covers integration, day-to-day
operations, and evaluation.

Every guide is written against the current release. If a CLI
flag, configuration key, or function signature in these pages
does not match the binary you are running, the binary is right
and the guide is stale; please
[file an issue](https://github.com/mwunsch/egghead/issues).
