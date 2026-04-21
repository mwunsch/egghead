# Egghead

Record-store-first multi-agent system on Elixir/OTP. Plain markdown records
under `records/` are the substrate; agents are participants in the graph,
not owners of it. Design docs live in the store — start with
[`records/design/egghead-overview.md`](records/design/egghead-overview.md)
or browse via `egghead` (TUI).

## Rules (read first)

- **Don't commit `records/`** unless explicitly told. It's a live data store.
- **Don't commit `CLAUDE.md`** unless explicitly told.
- **Don't patch `native/bridge/`** without understanding the Zig NIF
  build. The bridge links against `libopentui.dylib` at compile time.
- **Run `mix format` before committing any Elixir change.** CI enforces
  `mix format --check-formatted` and will fail the release workflow
  (which then requires retagging). Format touched files, or
  `mix format` the whole tree if unsure, and stage the result.
- **After every commit, update `records/meta/session-log.md`** with the
  commit hash and a short description, then play back the remaining
  "Next Areas" list to the user so we maintain continuity across sessions.
- The session log is the canonical record of "what's been done and what's
  next" — read it whenever you pick up work to understand context.

## Commands

```bash
egghead                          # Launch the TUI
egghead init                     # First-run setup wizard
egghead serve                    # Web + MCP HTTP server (headless)
egghead mcp                      # MCP stdio server (editor integration)
egghead llm list|add|remove|test|models
egghead agents list|new
egghead config [set K V | path]
egghead doctor                   # Diagnose setup problems
egghead logs                     # Tail application logs
ANTHROPIC_API_KEY=… iex -S mix   # Interactive (full system loaded)
mix test                         # Test suite
mix format
```

All commands support `--help` (instant, via bash). Commands that touch
configuration support `--config PATH` to override the config file.

Without any provider configured (no API keys, no config file), the app
**gracefully degrades to a record-store-only interface**: the TUI records
browser, MCP record tools, and `Egghead.search/get/list/...` all work.
Anything that needs to actually call an LLM (`Egghead.chat`,
`Egghead.consult`, `Egghead.prompt`, agent activation in chat rooms)
returns a clean error.

## Configuration

Config lives at `~/.config/egghead/config.yml` (respects `$XDG_CONFIG_HOME`).
Override with `$EGGHEAD_CONFIG` env var or `--config PATH` flag.

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

Records default to `~/.egghead/`. Logs go to
`~/.local/state/egghead/egghead.log` (respects `$XDG_STATE_HOME`).

## Architecture

```
Egghead.Supervisor (one_for_one)
├── Phoenix.PubSub
├── RecordSupervisor (rest_for_one)
│   ├── Index           — SQLite, derived & rebuildable
│   └── RecordStore     — file watcher, parser, write barrier
└── Agent.LayerSupervisor (rest_for_one)
    ├── LLM.Registry    — multi-provider, env-var detection
    ├── Chat.Coordinator — activation gating, /pass enforcement
    └── Agent.Supervisor (DynamicSupervisor)
        ├── index       — built-in store agent (model from config)
        └── agents/*    — defined as records with class: agent
```

The record store is isolated from the agent layer. If LLM.Registry crashes
and all agents restart, search/get/list/backlinks keep serving. The clean
record store outlives any individual session.

### Logging

Centralized in `Egghead.Application.start/2` via `:log_mode` app env:

- `:console` (default) — stdout, for `iex` and `egghead serve`
- `:file` — redirect to XDG log file, for TUI
- `:silent` — redirect to file, no console, for CLI commands

Log routing happens before the supervision tree starts.

### Design principles

- **Knowledge graph as institution.** Records survive agents. Agents are
  staff, not the organization.
- **Plain files are the universal interface.** Markdown on a filesystem,
  not a database.
- **Graph topology, sparse activation.** Agents collaborate through a
  shared transcript and self-select via @-mentions, `/pass`, and tag-based
  relevance gating. Default activation is serial (each agent reads
  peers' output before speaking). Three dialogue modes: open messages
  (serial, strict `/pass`), `@everyone` huddle (serial, must-respond),
  `@jam` (parallel cacophony). See `records/design/coordinator.md` and
  `records/research/multi-agent-topology-patterns.md`.
- **Capability-based mutation control.** Reads are free; writes follow a
  graduated spectrum enforced at the infrastructure level.

## Public API (`Egghead` module)

The `Egghead` module is the supported entry point for both `iex` and
library embedding. Prefer reusing these over reinventing.

### Records

| Function | Purpose |
|---|---|
| `get_record/1`, `list_records/0` | Fetch by id, list all |
| `search/2` | FTS5 query with class/tag filter |
| `find_links/2`, `find_backlinks/1` | Forward/reverse traversal |
| `recent/1` | Recently updated |
| `create_record/1`, `update_record/2` | Validate, write, re-index |

### Agents

| Function | Purpose |
|---|---|
| `prompt/3` | 1:1 prompt to a single agent |
| `list_agents/0` | Roster + token / context % |
| `handoff/2` | Summarize + clear, accepts `room_id:` opt for room-targeted handoff |
| `save_insights/1` | Distill session to a deliberation record |

### Chat rooms

| Function | Purpose |
|---|---|
| `create_room/1`, `default_room/0` | Lifecycle |
| `list_rooms/0`, `room_exists?/1` | Discover live rooms |
| `chat/2` | Send a user message |
| `chat_continue/1` | Reset turn budget; replay queued mentions |
| `chat_save/1` | Persist transcript as a `class: transcript` record |
| `chat_transcript/1` | Read full transcript |
| `watch/1` | Stream room events to stdout (RoomLogger) |

### Consultation

| Function | Purpose |
|---|---|
| `consult/2` | Ephemeral room: ask, get aggregated responses, auto-saved & stopped |

## CLI

`bin/egghead` is a thin wrapper that calls `mix egghead` (which bridges
to `Egghead.CLI.main/1`). All CLI logic lives in `lib/egghead/cli/`
as regular modules — no Mix tasks. See `records/design/cli.md` for
the full CLI design document.

### Interactive widgets (`Egghead.CLI.Widgets`)

CLI commands use the OpenTUI Bridge NIF for interactive input:
`Bridge.enter_raw_mode/0` + `Input.read_one_key/1` for keyboard,
`Readline` for text editing, ANSI escape codes for rendering.

- **Select**: Arrow-key `▸` navigation, type-to-filter
- **Multiselect**: Arrow keys + space to toggle `[✓]`/`[ ]`
- **Input**: Ghost text default (Tab to accept), full Readline bindings
- **Secret**: Partial reveal (prefix cleartext, rest masked)
- **Spinner**: Simple spawned process animation
- **Confirm**: `IO.gets` y/n

Falls back to `Egghead.CLI.Prompts` when the NIF is unavailable.

## TUI

`egghead` (or `egghead tui`). Built on OpenTUI (Zig NIF) with an
Elm-architecture runtime. See `lib/egghead/open_tui/README.md` for the
framework documentation. Logs go to `~/.local/state/egghead/egghead.log`
— never to stdout, which would corrupt the alt-screen rendering.

### Two modes

- **Records mode** (default) — Notational Velocity-style: instant search,
  arrow nav, markdown preview pane (wikilinks/tables/footnotes/task lists),
  Tab cycles links, Enter follows or opens in `$EDITOR`, type a new title
  to create a record (search-as-create phantom row).
- **Chat mode** (`/chat`) — IRC-style: shared transcript with agents,
  nick-prefixed messages, `/me`-style action lines for tool calls and
  `/pass` yields (atmospheric flavor text from `PassActions` pool),
  paragraph-by-paragraph streaming (gated on `\n\n`), ghost-text
  @-mention autocomplete (includes `@everyone` huddle, `@jam`
  cacophony), mode-aware slash command palette.

### Slash commands per mode

| Mode | Commands |
|---|---|
| records | `/quit` `/help` `/new` `/chat` `/system` `/debug` |
| chat | `/save` `/continue` `/handoff <agent>` `/join <room-or-transcript>` `/mute <agent>` `/unmute <agent>` `/leave` `/help` `/quit` |

Quit: `Ctrl+Q` (in-app) or `Ctrl+C → a` (BEAM abort). Esc returns from
chat mode to records mode.

### TUI gotchas (have burned us before)

- **Don't run the TUI from `iex`** — the NIF needs exclusive terminal
  ownership; the IEx group leader and raw mode fight.
- **`$EDITOR` uses `{:suspend, fn}`** — the runtime tears down the terminal,
  runs the function (editor gets a clean tty), then restores. If you see
  garbage after editor exit, `Bridge.drain_input` isn't catching something.
- **The NIF opens `/dev/tty` directly** — not stdin. This is correct for
  POSIX (resolves to the controlling terminal) and works with PTY wrappers
  like termscope that call `forkpty()`. But `System.cmd("stty", ...)`
  still fails inside the BEAM because it pipes stdin.
- **`enable_mouse(handle, true)` floods input** with motion events on every
  cursor move, drowning keyboard events. Use `false` (button + wheel only).
  In-app mouse text selection needs a different approach (see below).
- **`ANSI :black` ≠ terminal default background** on most setups. Use `nil`
  bg → SGR 49 for content; only set explicit bg on chrome bars and selection
  highlights.
- **Streaming flushes on `\n\n`**, not on every newline. The chat
  display would be unreadable otherwise. See coordinator on_chunk.
- **`Egghead.OpenTUI.*` modules must not reference `Egghead.*` application
  modules** (code or docs). The framework layer is application-agnostic.
  PubSub is injected via `:pubsub_server` opt, not hardcoded.

## MCP

15 tools exposed over MCP. Two transports, one handler (`Egghead.MCP.Handler`):

- **Stdio** (`egghead mcp`): JSON-RPC over stdin/stdout. Configured in
  `.mcp.json` for editor integrations (Claude Code, etc.).
- **HTTP** (`POST /mcp`): Mounted in Phoenix router. Available when
  `egghead serve` is running on the same port as the web UI.

Tool names are `egghead_*`-namespaced:

- Records: `egghead_search`, `egghead_get`, `egghead_list`, `egghead_create`,
  `egghead_update`, `egghead_find_links`, `egghead_backlinks`, `egghead_recent`
- Agents: `egghead_agents`, `egghead_prompt`, `egghead_handoff`, `egghead_save`
- Consultation: `egghead_consult`
- Providers: `egghead_providers`, `egghead_models`

`egghead_consult` is the primary integration for external clients that
want to ask the swarm a question without managing rooms themselves.

## Versioning & Releases

### Version string

The version is **computed at compile time** in `mix.exs` from the date
and the current git SHA:

- Clean tree: `2026.4.14+61d171a` (CalVer + 7-char git SHA)
- Dirty tree: `2026.4.14+dirty`
- No git: `0.0.0+nogit`

No manual version bumps. Don't edit a `version: "x.y.z"` line — there
isn't one. The format is `Version.parse/1`-compatible.

### Cutting a release

```bash
# After your changes are committed and pushed to main:
git tag -a v2026.4.14 -m "Brief release note"
git push origin v2026.4.14
```

GH Actions (`.github/workflows/release.yml`) on a `v*` tag push:

1. **test** (Ubuntu) — installs `inotify-tools`, runs `mix test`
2. **build** (matrix) — Burrito binaries for `macos_arm64` (macos-latest)
   and `linux_x64` (ubuntu-latest). Each runner gets `setup-zig@v2`
   pinned to the version Burrito requires (currently `0.15.2` —
   check `deps/burrito/lib/burrito.ex` if bumping). Linux gets
   `xz-utils`. Both run `mix phx.digest` before `mix release`.
3. **release** — collects artifacts, creates a GitHub Release with
   auto-generated notes from PRs.

### When a release fails

If the workflow fails before the **release** job publishes, the tag
exists on GitHub but no GitHub Release does. It's safe to fix and
retag at the same name:

```bash
gh release view v2026.4.14   # confirms "release not found"
git tag -d v2026.4.14
git push origin :refs/tags/v2026.4.14
git tag -a v2026.4.14 -m "..." <new-sha>
git push origin v2026.4.14
```

If the **release** job already ran and published, **don't** move the
tag — bump to a new date (`v2026.4.15`) instead. Users may have
downloaded the published artifacts.

### Burrito cache & version coupling

Burrito unpacks the embedded payload to
`~/Library/Application Support/.burrito/<app>_erts-<v>_<version>/`
(macOS path; analogous on Linux/Windows) and **keys the cache on the
version string**. Two builds with the same version → second one runs
the first one's unpacked code. The CalVer + SHA scheme auto-busts the
cache on every commit, so this is invisible during normal development —
but if you ever pin the version manually, you must bump it for the
binary to actually reflect your changes.

### Linux runtime dep

The published binary needs `inotify-tools` on Linux for the file
watcher (records reindex on external edits). `install.sh` warns the
user with the right apt/dnf/pacman/zypper command if `inotifywait` is
missing. `egghead doctor` does the same check (Linux-only, skipped
on macOS). Don't silent-degrade the watcher — it's load-bearing.

### Burrito version pin

`deps/burrito/lib/burrito.ex` enforces an exact Zig version in its
`pre_check`. When upgrading Burrito, check that constant and update
`mlugg/setup-zig@v2`'s `version:` in `release.yml` to match. Burrito's
zig is for compiling its launcher; build_dot_zig has a separate pinned
zig (in `deps/build_dot_zig/priv/`) for our NIF. Two zigs, no overlap.

### What CI installs that the dev machine has implicitly

| Dep | Why | Where |
|---|---|---|
| `inotify-tools` (Linux) | `file_system` runtime backend | test job + user's machine |
| `xz-utils` (Linux) | Burrito payload compression | build job only |
| `zig` 0.15.2 | Burrito launcher compile | build job only |

macOS ships `xz` and uses native FSEvents — nothing to install.

### See also

`records/design/cli.md` "Burrito gotchas" section for the war stories
behind these conventions (cache trap, MIX_ENV=prod requirement,
phx.digest, build_dot_zig / Zig 0.15 incompatibility, `-noshell`,
`Burrito.Util.Args.argv()` vs `System.argv()`).

## Conventions

- **Records**: `~/.egghead/*.md` (Markdown or org-mode, frontmatter optional)
- **Agents**: records with `class: agent`, body = system prompt, frontmatter
  configures `model`, `capabilities`, `tags`, `disposition`
- **Index**: `~/.egghead/.egghead/index.db` (derived, rebuildable from sources)
- **Config**: `~/.config/egghead/config.yml` (XDG), or `$EGGHEAD_CONFIG`
- **Logs**: `~/.local/state/egghead/egghead.log` (XDG)
- **Model IDs**: `provider/model` (e.g. `anthropic/claude-sonnet-4-6`)
- **MCP**: `.mcp.json` (stdio) or `POST /mcp` on the web server (HTTP)
- **Tests**: `:memory:` SQLite, temp dirs, `start_record_store: false` in
  test config to prevent the file watcher from interfering. Just `mix test`.

## Key files (start here when picking up work)

| File | Purpose |
|---|---|
| `records/meta/session-log.md` | What's been done, commit hashes, what's next |
| `records/design/egghead-overview.md` | The full design picture |
| `records/design/cli.md` | CLI design and architecture |
| `lib/egghead.ex` | Public API surface |
| `lib/egghead/config.ex` | Config loading/saving (XDG paths) |
| `lib/egghead/agent/agent.ex` | Agent GenServer, identity, session spawner |
| `lib/egghead/agent/session.ex` | Per-room session, tool-use loop, handoff |
| `lib/egghead/agent/wizard.ex` | Programmatic agent creation API |
| `lib/egghead/chat/room.ex` | Shared transcript, turn budget, PubSub |
| `lib/egghead/chat/coordinator.ex` | Activation gating, /pass, mute, dialogue modes |
| `lib/egghead/chat/pass_actions.ex` | System-wide /pass flavor text pool |
| `lib/egghead/chat/transcript_parser.ex` | Inverse of format_transcript (for /join rehydrate) |
| `lib/egghead/agent/tools.ex` | Agent-facing tool implementations |
| `lib/egghead/mcp/handler.ex` | MCP tool surface for external clients |
| `lib/egghead/mcp/server.ex` | MCP stdio transport |
| `lib/egghead/web/mcp_controller.ex` | MCP HTTP transport (Phoenix) |
| `lib/egghead/llm/registry.ex` | Multi-provider, env detection, model resolve |
| `lib/egghead/cli/widgets.ex` | Interactive CLI widgets (OpenTUI Bridge) |
| `lib/egghead/cli/prompts.ex` | Fallback prompts for non-TTY |
| `lib/egghead/open_tui/` | OpenTUI framework (see README.md inside) |
| `lib/egghead/open_tui/runtime.ex` | Elm event loop, command execution |
| `lib/egghead/open_tui/bridge.ex` | Zig NIF interface to libopentui |
| `lib/egghead/tui/app.ex` | Root Elm component (records + chat modes) |
| `lib/egghead/tui/records/` | Records screen (Model/Update/View) |
| `lib/egghead/tui/chat/` | Chat screen (Model/Update/View) |
| `bin/egghead` | CLI entry point (Bash wrapper for Mix) |
| `lib/mix/tasks/egghead.ex` | One-line Mix task bridge to CLI.main |

## Quick `iex` recipes

```elixir
Egghead.watch()                    # Watch default chat room (stdout)
Egghead.chat("Roll call!")         # Send to default room
Egghead.chat("@agents/scout ...")  # Direct address
Egghead.chat("@everyone ...")      # Huddle: serial, must-respond
Egghead.chat("@jam ...")           # Cacophony: parallel, low threshold
Egghead.chat_continue()            # Grant more rounds
Egghead.chat_save()                # Save transcript as class:transcript record
Egghead.consult("What about X?")   # Ephemeral room, swarm responds, returns result
Egghead.prompt("agents/scout", "direct 1:1 prompt")
Egghead.handoff("agents/scout")    # Manual context handoff
```

## Further reading

In `records/design/`:

- `egghead-overview.md` — full design picture (read first)
- `cli.md` — CLI design and architecture
- `chat-room.md` — collaborative chat architecture
- `coordinator.md` — activation gating, addressing, [PASS]
- `context-pressure.md` — handoffs, lean transcript diff
- `security-model.md` — mutation spectrum and capability tokens
- `tui.md` — TUI design and mockups
- `tui-theme-system.md` — owned palette plan (Mocha/Latte)
- `decisions.md` — decision log

In `lib/egghead/open_tui/`:

- `README.md` — OpenTUI framework docs, module inventory, unexposed capabilities
