# Egghead — Claude Code Context

Record-store-first multi-agent system on Elixir/OTP. Design docs live in
the record store itself: `records/design/*.md`. Start with
`records/design/egghead-overview.md` for the full picture.

## Commands

```bash
iex -S mix                          # Interactive (set ANTHROPIC_API_KEY)
mix test --exclude mcp_integration  # 145 tests
mix format                          # Format
```

## Supervision Tree

```
Egghead.Supervisor (one_for_one)
├── PubSub
├── RecordSupervisor (rest_for_one)
│   ├── Index (SQLite)
│   └── RecordStore (file watcher)
└── Agent.LayerSupervisor (rest_for_one)
    ├── LLM.Registry
    ├── Chat.Coordinator (planned)
    └── Agent.Supervisor (DynamicSupervisor)
        ├── egghead (built-in default / coordinator)
        └── agents/* (from records)
```

Record store is isolated from agent layer. Registry crash restarts
agents but search/get/list keep working.

## Current Build: Chat Room

Building the multi-agent chat room with:
- Shared transcript (Room GenServer)
- Relevance-gated activation (coordinator's activate_agents tool)
- Graph topology (agents see each other, coordinator gates entry not content)
- Turn budget as circuit breaker
- Agent-to-agent @-mentions

## Conventions

- Records: `records/` (Markdown/org-mode, all frontmatter optional)
- Agents: records with `class: agent`, body = system prompt
- Index: `records/.egghead/index.db` (derived, rebuildable)
- Providers: `~/.egghead/providers.yml` or env vars
- MCP: `.mcp.json` (stdio) or `localhost:8642/mcp` (HTTP)
- Tests: `:memory:` SQLite, temp dirs, `start_record_store: false` in test config
- Models: `provider/model` format (e.g. `anthropic/claude-sonnet-4-6`)
