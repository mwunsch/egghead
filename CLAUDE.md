# Egghead

Record-store-first multi-agent system on Elixir/OTP. Plain markdown records
under `records/` are the substrate; agents are participants in the graph,
not owners of it. Design docs live in the store — start with
[`records/design/egghead-overview.md`](records/design/egghead-overview.md)
or browse via `mix egghead.tui`.

## Rules (read first)

- **Don't commit `records/`** unless explicitly told. It's a live data store.
- **Don't commit `CLAUDE.md`** unless explicitly told.
- **Don't patch `deps/term_ui/`** — it's gitignored and gets wiped on the
  next dep update. Real fixes go upstream; document workarounds in
  `records/design/termui-learnings.md`.
- **After every commit, update `records/meta/session-log.md`** with the
  commit hash and a short description, then play back the remaining
  "Next Areas" list to the user so we maintain continuity across sessions.
- The session log is the canonical record of "what's been done and what's
  next" — read it whenever you pick up work to understand context.

## Commands

```bash
ANTHROPIC_API_KEY=… iex -S mix      # Interactive (full system loaded)
mix egghead.tui                      # TUI (or ./bin/egghead)
mix test --exclude mcp_integration   # Test suite
mix format
```

Without any provider configured (no API keys, no `~/.egghead/providers.yml`),
the app **gracefully degrades to a record-store-only interface**: the TUI
records browser, MCP record tools, and `Egghead.search/get/list/...` all
work. Anything that needs to actually call an LLM (`Egghead.chat`,
`Egghead.consult`, `Egghead.prompt`, agent activation in chat rooms)
returns a clean error.

## Architecture

```
Egghead.Supervisor (one_for_one)
├── Phoenix.PubSub
├── RecordSupervisor (rest_for_one)
│   ├── Index           — SQLite, derived & rebuildable
│   └── RecordStore     — file watcher, parser, write barrier
└── Agent.LayerSupervisor (rest_for_one)
    ├── LLM.Registry    — multi-provider, env-var detection
    ├── Chat.Coordinator — activation gating, [PASS] enforcement
    └── Agent.Supervisor (DynamicSupervisor)
        ├── index       — built-in store agent (Haiku)
        └── agents/*    — defined as records with class: agent
```

The record store is isolated from the agent layer. If LLM.Registry crashes
and all agents restart, search/get/list/backlinks keep serving. The clean
record store outlives any individual session.

### Design principles

- **Knowledge graph as institution.** Records survive agents. Agents are
  staff, not the organization.
- **Plain files are the universal interface.** Markdown on a filesystem,
  not a database.
- **Graph topology, sparse activation.** Agents collaborate through a
  shared transcript and self-select via @-mentions, [PASS], and tag-based
  relevance gating. Star/tree delegation patterns are empirically inferior
  for this kind of work — see `records/design/coordinator.md`.
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
| `list_agents/0`, `agent_usage/1` | Roster + token / context % |
| `clear_history/1` | Reset session history |
| `handoff/2` | Summarize + clear, optionally continue with new prompt |
| `save_insights/1` | Distill session to a deliberation record |

### Chat rooms

| Function | Purpose |
|---|---|
| `create_room/1`, `default_room/0` | Lifecycle |
| `chat/2` | Send a user message |
| `chat_continue/1` | Reset turn budget; replay queued mentions |
| `chat_save/1` | Persist transcript as a deliberation record |
| `chat_transcript/1` | Read full transcript |
| `set_room_mode/2` | `:staggered` (default) or `:serial` activation |
| `watch/1` | Stream room events to stdout (RoomLogger) |

### Consultation

| Function | Purpose |
|---|---|
| `consult/2` | Ephemeral room: ask, get aggregated responses, auto-saved & stopped |

## TUI

`mix egghead.tui` (or `./bin/egghead`). Built on TermUI (Elm architecture).
Logs go to `/tmp/egghead.log` — never to stdout, which would corrupt the
alt-screen rendering. Pinned to a specific TermUI ref because of upstream
bugs we work around; see `records/design/termui-learnings.md`.

### Two modes

- **Records mode** (default) — Notational Velocity-style: instant search,
  arrow nav, markdown preview pane (wikilinks/tables/footnotes/task lists),
  Tab cycles links, Enter follows or opens in `$EDITOR`, type a new title
  to create a record (search-as-create phantom row).
- **Chat mode** (`/chat`) — IRC-style: shared transcript with the swarm,
  nick-prefixed messages, `/me`-style action lines for tool calls,
  paragraph-by-paragraph streaming (gated on `\n\n`), ghost-text @-mention
  autocomplete, mode-aware slash command palette.

### Slash commands per mode

| Mode | Commands |
|---|---|
| records | `/quit` `/help` `/new` `/chat` `/system` `/debug` |
| chat | `/save` `/continue` `/handoff <agent>` `/leave` `/help` `/quit` |

Quit: `Ctrl+Q` (in-app) or `Ctrl+C → a` (BEAM abort). Esc returns from
chat mode to records mode.

### TUI gotchas (have burned us before)

- **Two `Style` modules in TermUI**: use `TermUI.Renderer.Style`, NOT
  `TermUI.Style`. Easy to import the wrong one and get nil cells.
- **`handle_info/2` MUST return `{state, []}`**, not bare `state`. The
  catch-all clause in `app.ex` was wrong for months and only surfaced when
  chat mode introduced a PubSub subscriber.
- **Don't run the TUI from `iex`** — TermUI needs exclusive terminal
  ownership; the IEx group leader and TermUI raw mode fight.
- **`mix egghead.tui` redirects logs** to `/tmp/egghead.log`. If you see
  log spam in the alt screen during dev, something is bypassing this.
- **`$EDITOR` flow uses quit-and-restart** (BubbleTea-style): TUI quits,
  parent loop spawns the editor with `:nouse_stdio` Port, restores raw
  mode, drains stale terminal capability responses, restarts the runtime.
  If you see garbage on top of the screen after editor exit, the drain
  isn't catching something.
- **`stty` calls go through `Port.open(:nouse_stdio)`**, NOT `System.cmd` —
  the latter pipes stdin and the TTY operations silently fail.
- **`ANSI :black` ≠ terminal default background** on most setups. Use `nil`
  bg → Cell `:default` → SGR 49 for content; only set explicit bg on
  chrome bars and selection highlights.
- **Streaming flushes on `\n\n`**, not on every newline. The chat
  display would be unreadable otherwise. See coordinator on_chunk.

## MCP

14 tools exposed over MCP. Stdio via `.mcp.json`, HTTP on
`localhost:8642/mcp`. Tool names are `egghead_*`-namespaced:

- Records: `egghead_search`, `egghead_get`, `egghead_list`, `egghead_create`,
  `egghead_find_links`, `egghead_backlinks`, `egghead_recent`
- Agents: `egghead_agents`, `egghead_prompt`, `egghead_handoff`, `egghead_save`
- Consultation: `egghead_consult`
- Providers: `egghead_providers`, `egghead_models`

`egghead_consult` is the primary integration for external clients that
want to ask the swarm a question without managing rooms themselves.

## Conventions

- **Records**: `records/*.md` (Markdown or org-mode, frontmatter optional)
- **Agents**: records with `class: agent`, body = system prompt, frontmatter
  configures `model`, `capabilities`, `tags`, `disposition`
- **Index**: `records/.egghead/index.db` (derived, rebuildable from sources)
- **Providers**: `~/.egghead/providers.yml` or `*_API_KEY` env vars
- **Model IDs**: `provider/model` (e.g. `anthropic/claude-sonnet-4-6`)
- **MCP**: `.mcp.json` (stdio) or `localhost:8642/mcp` (HTTP)
- **Tests**: `:memory:` SQLite, temp dirs, `start_record_store: false` in
  test config to prevent the file watcher from interfering

## Key files (start here when picking up work)

| File | Purpose |
|---|---|
| `records/meta/session-log.md` | What's been done, commit hashes, what's next |
| `records/design/egghead-overview.md` | The full design picture |
| `lib/egghead.ex` | Public API surface |
| `lib/egghead/agent/agent.ex` | Agent GenServer, identity, session spawner |
| `lib/egghead/agent/session.ex` | Per-room session, tool-use loop, handoff |
| `lib/egghead/chat/room.ex` | Shared transcript, turn budget, PubSub |
| `lib/egghead/chat/coordinator.ex` | Activation gating, [PASS] enforcement |
| `lib/egghead/agent/tools.ex` | Agent-facing tool implementations |
| `lib/egghead/mcp/handler.ex` | MCP tool surface for external clients |
| `lib/egghead/llm/registry.ex` | Multi-provider, env detection, model resolve |
| `lib/egghead/tui/app.ex` | Root Elm component (records + chat modes) |
| `lib/egghead/tui/markdown.ex` | Earmark AST → styled terminal text |
| `lib/egghead/tui/state.ex` | TUI state struct |
| `lib/egghead/tui/chat_render.ex` | Chat-mode entry rendering |
| `lib/mix/tasks/egghead.tui.ex` | TUI mix task (logger redirect, cleanup) |
| `test/tui/app_test.exs` | Headless TUI tests (Runtime skip_terminal: true) |

## Quick `iex` recipes

```elixir
Egghead.watch()                    # Watch default chat room (stdout)
Egghead.chat("Roll call!")         # Send to default room
Egghead.chat("@agents/scout ...")  # Direct address
Egghead.chat("@everyone ...")      # Broadcast all agents
Egghead.chat_continue()            # Grant more rounds
Egghead.chat_save()                # Save transcript as deliberation record
Egghead.consult("What about X?")   # Ephemeral room, swarm responds, returns result
Egghead.prompt("agents/scout", "direct 1:1 prompt")
Egghead.handoff("agents/scout")    # Manual context handoff
```

## Further reading

In `records/design/`:

- `egghead-overview.md` — full design picture (read first)
- `chat-room.md` — collaborative chat architecture
- `coordinator.md` — activation gating, addressing, [PASS]
- `context-pressure.md` — handoffs, lean transcript diff
- `security-model.md` — mutation spectrum and capability tokens
- `tui.md` — TUI design and mockups
- `termui-learnings.md` — verified TermUI API behavior, known pitfalls
- `tui-theme-system.md` — owned palette plan (Mocha/Latte)
- `decisions.md` — decision log
