# Egghead

A consultable record store with agent perspectives, built on Elixir/OTP.

Plain Markdown and org-mode files sit at the center. A SQLite graph index
materializes queries. AI agents with configurable dispositions read, reason
about, and contribute to the shared knowledge. External tools consult
Egghead via MCP.

## Quick Start

```bash
mix deps.get
export ANTHROPIC_API_KEY=your-key-here
iex -S mix
```

```elixir
Egghead.create_record(%{id: "ideas/first", title: "First Thought", tags: ["meta"], body: "Content."})
Egghead.search("first")
Egghead.prompt("egghead", "What do we know so far?")
```

Or drop `.md` files in `records/` — the file watcher picks them up.

## Records

Markdown with optional YAML frontmatter. All metadata is optional — id
derives from filename, timestamps from the filesystem, author from file
owner. Subdirectories are supported. Arbitrary frontmatter keys are preserved.

Four record classes: `durable` (permanent knowledge), `inbox` (ephemeral),
`deliberation` (agent conversation trails), `agent` (agent configuration).

## Agents

Agents are records with `class: agent`. The body is the system prompt.
Meta fields set model, provider, capabilities. Drop a file, agent starts.
Edit it, agent restarts. Delete it, agent terminates.

Agents decide when to use their tools (search, read, create, update records).
No forced behavior — the LLM reasons and calls tools as needed.

## MCP

Stdio transport (for Claude Code) and HTTP transport (for anything, from
anywhere). 11 tools covering search, CRUD, graph traversal, and agent
prompting.

See `.mcp.json` for the project-local config. For global access:

```bash
claude mcp add --transport stdio --scope user egghead \
  -- bash -c "cd /path/to/egghead && mix run --no-halt -e 'Egghead.MCP.Server.start()'"
```

## Documentation

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

```bash
mix docs
```

## Acknowledgements

The web interface uses icons from the [Haiku](https://www.haiku-os.org/)
project, licensed under the MIT license. Haiku's icons are free to re-use
and modify. See [haiku-inc.org/trademarks/haiku_icons](https://www.haiku-inc.org/trademarks/haiku_icons/)
for details.

## License

Egghead is licensed under the [GNU Affero General Public License v3.0 or
later](LICENSE) (AGPL-3.0-or-later). This is a strong copyleft license: if
you run a modified version of Egghead and let users interact with it over
a network, you must offer them the corresponding source code under the
same license.

If AGPL doesn't fit your use case, get in touch.
