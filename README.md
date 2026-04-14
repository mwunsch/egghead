# Egghead

A consultable record store with agent perspectives, built on Elixir/OTP.

Plain Markdown and org-mode files sit at the center. A SQLite graph index
materializes queries. AI agents with configurable dispositions read, reason
about, and contribute to the shared knowledge. External tools consult
Egghead via MCP.

## Install

### Binary (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/mwunsch/egghead/main/install.sh | sh
```

Installs to `~/.local/bin/egghead`. Single self-contained binary, no
runtime dependencies — except on Linux, see below.

Releases are also available on the [GitHub releases page](https://github.com/mwunsch/egghead/releases)
for macOS (Apple Silicon, Intel) and Linux (x86_64, arm64).

#### Linux: install inotify-tools

Egghead watches your records directory so the index stays in sync as
files change (editor saves, agents writing via MCP, git pulls, Obsidian,
etc). On Linux this needs `inotifywait` from `inotify-tools`. macOS uses
FSEvents — nothing to install.

```bash
sudo apt-get install inotify-tools     # Debian / Ubuntu
sudo dnf install inotify-tools         # Fedora
sudo pacman -S inotify-tools           # Arch
```

The `install.sh` script will warn you if it's missing. `egghead doctor`
will too.

### From source

Requires Elixir 1.19+, Erlang/OTP 28+, and Zig (managed automatically
by `build_dot_zig`).

```bash
git clone https://github.com/mwunsch/egghead.git
cd egghead
mix deps.get
./bin/egghead
```

## Quick Start

```bash
egghead init      # First-run wizard: records dir, LLM provider, default model
egghead           # Launch the TUI (Notational Velocity-style records browser
                  #   + IRC-style chat with agents)
```

Other commands:

```bash
egghead serve     # Web UI + MCP HTTP endpoint at http://localhost:4000
egghead mcp       # MCP stdio server (for editor integration)
egghead agent     # list / new
egghead llm       # list / add / remove / test / models
egghead config    # show / set / path
egghead doctor    # diagnose setup problems
egghead logs      # tail application logs
```

All commands support `--help` and `--config PATH`.

## Records

Markdown (or org-mode) with optional YAML frontmatter. All metadata is
optional — id derives from filename, timestamps from the filesystem,
author from file owner. Subdirectories are supported. Arbitrary
frontmatter keys are preserved.

Records live in `~/.egghead/` by default (configurable via
`~/.config/egghead/config.yml` or the `EGGHEAD_RECORDS` env var).

Four record classes: `durable` (permanent knowledge), `inbox`
(ephemeral), `deliberation` (agent conversation trails), `agent`
(agent configuration).

## Agents

Agents are records with `class: agent`. The body is the system prompt.
Frontmatter sets model, capabilities, tags, disposition. Drop a file,
agent starts. Edit it, agent restarts. Delete it, agent terminates.

Agents decide when to use their tools (search, read, create, update
records). No forced behavior — the LLM reasons and calls tools as
needed. They collaborate through a shared chat transcript and self-select
via @-mentions, `[PASS]`, and tag-based relevance gating.

## MCP

15 tools covering record CRUD, graph traversal, agent prompting, and
ephemeral consultations. Two transports:

- **Stdio** (`egghead mcp`) — JSON-RPC over stdin/stdout, for editor
  integrations. Wire up via `.mcp.json`:

  ```json
  {
    "mcpServers": {
      "egghead": { "command": "egghead", "args": ["mcp"] }
    }
  }
  ```

- **HTTP** (`POST /mcp`) — mounted in the Phoenix router when `egghead
  serve` is running.

The `egghead_consult` tool is the primary integration for external clients
that want to ask the agent layer a question without managing rooms
themselves.

## Configuration

`~/.config/egghead/config.yml` (XDG-compliant; respects `$XDG_CONFIG_HOME`).
Override with `$EGGHEAD_CONFIG` or `--config PATH`.

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
`$XDG_STATE_HOME`).

## Documentation

```bash
mix docs
```

## Acknowledgements

The web interface uses icons from the [Haiku](https://www.haiku-os.org/)
project, licensed under the MIT license. Haiku's icons are free to re-use
and modify. See
[haiku-inc.org/trademarks/haiku_icons](https://www.haiku-inc.org/trademarks/haiku_icons/)
for details.

## License

Egghead is licensed under the [GNU Affero General Public License v3.0 or
later](LICENSE) (AGPL-3.0-or-later). This is a strong copyleft license: if
you run a modified version of Egghead and let users interact with it over
a network, you must offer them the corresponding source code under the
same license.

If AGPL doesn't fit your use case, get in touch.
