# Egghead

A notebook that writes back. A record store first, an agent layer
second, built on Elixir/OTP.

Plain Markdown and org-mode files sit at the center. A SQLite graph
index materializes queries over them. AI agents — defined as records
themselves, with capabilities declared in YAML — read the store,
reason against it, and contribute back. External tools consult the
whole arrangement over MCP.

## Install

### Binary (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/mwunsch/egghead/main/install.sh | sh
```

Installs to `~/.local/bin/egghead`. Single self-contained binary, no runtime dependencies — except on Linux, see below.

Releases are also available on the
[GitHub releases page](https://github.com/mwunsch/egghead/releases)
for macOS (Apple Silicon, Intel) and Linux (x86_64, arm64).

#### Linux: install inotify-tools and bubblewrap

Two extra packages on Linux:

- **`inotify-tools`** — the file watcher needs `inotifywait` to keep the
  index in sync as records change on disk (editor saves, agents writing
  over MCP, git pulls, Obsidian, etc).
- **`bubblewrap`** — the OS-level sandbox for agent-spawned subprocesses.
  Without it, agents that hold `proc.exec` capabilities run unsandboxed
  with a warning logged. macOS uses `sandbox-exec(1)` and FSEvents,
  both shipped by the OS — nothing to install.

```bash
sudo apt-get install inotify-tools bubblewrap   # Debian / Ubuntu
sudo dnf install inotify-tools bubblewrap       # Fedora
sudo pacman -S inotify-tools bubblewrap         # Arch
```

`install.sh` warns you if `inotifywait` is missing. `egghead doctor`
checks both at runtime.

### From source

Requires Elixir 1.19+, Erlang/OTP 28+. Zig is fetched and pinned
automatically by `build_dot_zig` for the OpenTUI NIF.

```bash
git clone https://github.com/mwunsch/egghead.git
cd egghead
mix deps.get
./bin/egghead
```

## Quick start

```bash
egghead init      # First-run wizard: records dir, LLM provider, default model
egghead           # Launch the TUI: Notational Velocity-style records browser
                  #                 + IRC-style chat room with your agents
```

Once `init` has written a config and an LLM provider is reachable,
the TUI starts in records mode. `/chat` switches to the chat room;
`Esc` returns. `Ctrl+Q` quits.

Without any provider configured, Egghead **gracefully degrades to a
record-store-only interface** — the records browser, MCP record tools,
and the read-side of the public API all work. Anything that needs to
call an LLM returns a clean error.

## Commands

```bash
egghead                          # Launch the TUI (default)
egghead init                     # First-run setup wizard
egghead serve                    # Web UI + MCP HTTP at http://localhost:4000
egghead mcp                      # MCP stdio server (for editor integration)
egghead agents <list|new|grant|revoke|capabilities>
egghead skills <list|check>      # Manage agent skills
egghead tools                    # Inspect agent tools and MCP servers
egghead rooms                    # List open chat rooms
egghead llm <list|add|remove|test|models>
egghead eval                     # Run multi-agent eval tasks
egghead config <show|set|path>
egghead doctor                   # Diagnose setup problems
egghead logs                     # Tail application logs
```

All commands support `--help` and `--config PATH`.

## Records

Markdown (or org-mode) with optional YAML frontmatter. Everything is
optional — id derives from the filename, timestamps from the
filesystem, author from the file owner. Subdirectories are supported.
Arbitrary frontmatter keys are preserved.

Records live in `~/.egghead/` by default (configurable via
`~/.config/egghead/config.yml` or the `EGGHEAD_RECORDS` env var). The
SQLite index is derived state at `$EGGHEAD_RECORDS/.egghead/index.db` and
can be rebuilt from the source files at any time.

## Agents

Agents are records with `class: agent`. The body is the system prompt.
Frontmatter sets the model, capabilities, and tags. Drop
a file, the agent starts. Edit it, the agent restarts. Delete it, the
agent terminates.

```yaml
---
class: agent
model: anthropic/claude-sonnet-4-6
capabilities:
  - records.read
  - records.create
  - "net.get{hosts=[*.github.com]}"
tags: [research, github]
---
You are a research assistant focused on the project's GitHub
issues. Cite sources by URL. Pass when you have nothing to add.
```

Agents decide when to use their tools — the LLM reasons and calls
tools as needed. They collaborate through a shared chat transcript
and self-select via `@`-mentions and tag-based relevance
gating. Three dialogue modes:

- **Open messages** — serial, agents can elect to `/pass` - skipping their turn. The default.
- **`@everyone`** — huddle: serial, must-respond.
- **`@jam`** — cacophony: parallel, low activation threshold.

## Capabilities & sandboxing

Authority is declarative. The `capabilities:` list in an agent's
frontmatter enumerates exactly what verbs that agent may perform —
read records, edit records, fetch a URL, run a subprocess, grant
authority to another agent. Bare grants for external resources
(`fs`, `net`, `proc`) are inert until explicitly scoped; bare grants
for internal resources (`records`, `agent`) cover the whole store.

```yaml
capabilities:
  - records.read
  - records.create
  - "net.get{hosts=[api.anthropic.com, *.github.com]}"
  - "proc.exec{cmds=[rg, jq, git]}"
```

Two layers enforce this:

1. **`Egghead.Capability.check/3`** — at every tool dispatch, the
   request is matched against the held grants. Denials surface to the
   LLM, the transcript, and the log, with a suggested YAML snippet
   that would widen the grant.
2. **`Egghead.Sandbox`** — when an agent reaches for a subprocess,
   it's spawned inside an OS-level fence: `sandbox-exec(1)` on macOS,
   `bwrap(1)` on Linux. Confined to the workspace declared in the
   grant; severed from the network unless the grant opens it.

Widening a capability is always a human act — you edit the agent's
record, or use `egghead agents grant <id>` for an interactive picker.
Agents cannot grant capabilities they don't already hold (privileges
attenuate downward only), and cannot grant new capabilities to
themselves.

## MCP

Fifteen tools covering record CRUD, graph traversal, agent prompting,
and ephemeral consultations. Two transports:

- **Stdio** (`egghead mcp`) — JSON-RPC over stdin/stdout, for editor
  integrations. Wire it up via `.mcp.json`:

  ```json
  {
    "mcpServers": {
      "egghead": { "command": "egghead", "args": ["mcp"] }
    }
  }
  ```

- **HTTP** (`POST /mcp`) — mounted in the Phoenix router whenever
  `egghead serve` is running, on the same port as the web UI.

`egghead_consult` is the primary integration for external clients
that want to ask the agent layer a question without managing rooms
themselves.

## Configuration

`~/.config/egghead/config.yml` (XDG-compliant; respects
`$XDG_CONFIG_HOME`). Override with `$EGGHEAD_CONFIG` or
`--config PATH`.

```yaml
records_dir: ~/.egghead

llm:
  - provider: anthropic
    api_key: "{env:ANTHROPIC_API_KEY}"

default_model: anthropic/claude-haiku-4-5

web:
  port: 4000
  host: localhost
  bind: 127.0.0.1
```

Logs go to `~/.local/state/egghead/egghead.log` (respects
`$XDG_STATE_HOME`). `egghead logs` tails them.

## Embedding

Egghead can be used as a library. The `Egghead` module is the
supported entry point — record CRUD, search, traversal, agent
prompting, room lifecycle, consultation, transcript persistence.

```elixir
{:ok, _} = Application.ensure_all_started(:egghead)

Egghead.search("ledger", class: "durable")
Egghead.consult("Should we adopt this RFC?")
Egghead.prompt("agents/scout", "summarize last week's commits")
```

```bash
mix docs    # Generate full module docs
```

## Acknowledgements

The web interface uses icons from the [Haiku](https://www.haiku-os.org/)
project, licensed under the MIT license. Haiku's icons are free to
re-use and modify. See
[haiku-inc.org/trademarks/haiku_icons](https://www.haiku-inc.org/trademarks/haiku_icons/)
for details.

## License

Egghead is licensed under the [GNU Affero General Public License
v3.0 or later](LICENSE) (AGPL-3.0-or-later). A strong copyleft: if
you run a modified version and let users interact with it over a
network, you must offer them the corresponding source under the same
license.

If AGPL doesn't fit your use case, get in touch.
