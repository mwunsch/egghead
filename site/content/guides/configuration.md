---
title: Configuration
weight: 14
---

Egghead tries to work with no configuration. Set an
`ANTHROPIC_API_KEY` in your shell, run `egghead`, and you have a
working system — records indexed, the built-in Index agent
responding, the TUI ready. Everything else has a sensible default.

When you do want to configure something, the surface is small and it
all lives in one YAML file. This guide covers what's in that file,
where to find it, how the precedence rules work, and what the CLI
does for you around it.

## Where the config lives

The config file is `~/.config/egghead/config.yml` by default,
respecting the XDG Base Directory spec:

- `$EGGHEAD_CONFIG` — if set, overrides everything. Point it at a
  directory (uses `config.yml` inside) or directly at a `.yml` file.
- `$XDG_CONFIG_HOME` — respected when set; e.g.,
  `$XDG_CONFIG_HOME/egghead/config.yml`.
- Otherwise: `~/.config/egghead/config.yml`.

`egghead config path` prints the resolved path. The file gets
`0600` permissions when Egghead writes it, on the assumption that
API keys might land inside.

## Precedence

Three layers, highest wins:

1. **Environment variables** — `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
   etc. At startup, the LLM registry checks for each known env var
   and auto-registers the provider if set. Overrides anything in the
   config file.
2. **Config file** — `config.yml`.
3. **Defaults** — baked in. `records_dir` is `~/.egghead`,
   `web.port` is `4000`, `web.bind` is `127.0.0.1`.

The upshot: you can run Egghead with no config file at all, and if
your environment has an API key set, it Just Works. The config file
is for persistent, considered choices; the environment is for
credentials and per-session overrides.

## First-run setup

`egghead init` walks a first-run wizard — see
[Getting started]({{< ref "getting-started" >}}) for the walkthrough.
The short version: pick a records directory,
pick a provider, paste an API key (or confirm use of the env var),
set a default model. Writes `config.yml` at the end. Skip it if you
prefer to hand-edit.

## Fully annotated config

```yaml
# Where records live. Defaults to ~/.egghead. The SQLite index
# lands at <records_dir>/.egghead/index.db — derived, rebuildable.
records_dir: ~/.egghead

# Drop-zone for portable skills outside the record store.
# Defaults to ~/.agents/skills.
skills_dir: ~/.agents/skills

# LLM providers. One entry per provider. Multiple entries of the
# same provider are allowed (useful for custom base_urls).
llm:
  - provider: anthropic
    api_key: "{env:ANTHROPIC_API_KEY}"

  - provider: openai
    api_key: "{env:OPENAI_API_KEY}"

  # Custom OpenAI-compatible endpoint — name distinguishes it
  # from the default openai entry.
  - provider: openai
    name: together
    base_url: https://api.together.xyz/v1
    api_key: "{env:TOGETHER_API_KEY}"

# Default model for new agents and 1:1 prompts. Provider/model form.
default_model: anthropic/claude-sonnet-4-6

# Default chat room — created automatically if missing.
default_room: default

# Web server + MCP HTTP endpoint.
web:
  port: 4000        # HTTP listen port
  host: localhost   # hostname in generated links
  bind: 127.0.0.1   # listen address (loopback by default)

# External MCP servers your agents can reach. Each requires a
# capability set that agents must hold to use the server.
mcp_servers:
  - name: playwright
    transport: stdio
    command: npx @playwright/mcp@latest
    requires:
      - net.get:
          hosts: ["*"]
```

Every section is optional. A config file of just
`default_model: anthropic/claude-sonnet-4-6` is a legal config.

## The `{env:VAR}` pattern

Anywhere a string value could be sensitive (`api_key`, `command`,
`headers`), you can write `{env:VAR_NAME}` and Egghead resolves it
from the environment at load time. The literal string stays in the
file; the secret does not.

```yaml
llm:
  - provider: anthropic
    api_key: "{env:ANTHROPIC_API_KEY}"
```

This keeps the config file safe to commit if you want version control
on your setup — secrets stay in the environment, structure stays in
git.

## LLM providers and env-var auto-detection

If your `llm:` section is empty (or you have no config file at all),
Egghead detects these env vars at startup and registers the
corresponding providers automatically:

| Provider    | Env var(s)                          |
|-------------|-------------------------------------|
| `anthropic` | `ANTHROPIC_API_KEY`                 |
| `openai`    | `OPENAI_API_KEY`                    |
| `google`    | `GOOGLE_API_KEY` or `GEMINI_API_KEY` |
| `xai`       | `XAI_API_KEY`                       |
| `groq`      | `GROQ_API_KEY`                      |
| `deepseek`  | `DEEPSEEK_API_KEY`                  |
| `mistral`   | `MISTRAL_API_KEY`                   |
| `openrouter`| `OPENROUTER_API_KEY`                |

For providers that speak OpenAI-compatible APIs (`xai`, `groq`,
`deepseek`, `mistral`, `openrouter`, plus local `ollama` and
`lmstudio`), Egghead ships presets with the right `base_url` so you
can just drop the provider name in.

`egghead llm list` shows what's configured. `egghead llm add` walks
an interactive setup.

## Model resolution

Models use `provider/model` form: `anthropic/claude-sonnet-4-6`,
`openai/gpt-4o`, `google/gemini-2.0-flash`.

Bare model names also work — `claude-sonnet-4-6` is inferred to
`anthropic`, `gpt-4o` to `openai`, `gemini-*` to `google`, and so on.
The prefix has to match a known family.

`egghead llm models` lists what each configured provider reports.

## Web + MCP

The web server binds to `127.0.0.1` (loopback) by default. You get
the LiveView UI, the MCP HTTP endpoint at `/mcp`, and that's it — on
the same port. No separate service for MCP.

| Key        | Default      | What it does                                 |
|------------|--------------|----------------------------------------------|
| `web.port` | `4000`       | HTTP port the server listens on              |
| `web.host` | `localhost`  | Hostname used in generated links             |
| `web.bind` | `127.0.0.1`  | Bind address. Set to `0.0.0.0` to expose externally |

See the [Running a node guide]({{< ref "running-a-node" >}}) for
what to do before you bind outside loopback — there are things to
think about, and none of them are surprising.

## External MCP servers

`mcp_servers:` lets your agents reach out to other MCP servers.
Playwright, a Linear MCP, a custom stdio server you wrote in any
language — Egghead connects as a client, enumerates the tools, and
exposes them to agents that hold the right capabilities.

```yaml
mcp_servers:
  - name: playwright
    transport: stdio
    command: npx @playwright/mcp@latest
    env:
      PLAYWRIGHT_HEADLESS: "1"
    requires:
      - net.get:
          hosts: ["*"]
      - net.post:
          hosts: ["*"]
```

The `requires:` list is declared in the same capability grammar as
an agent's own grants. When an agent tries to invoke a tool from an
external MCP server, Egghead checks the agent's grants against
`requires:` — if the agent lacks what the server needs, the tool is
filtered out. The MCP server itself is never asked to enforce
anything; scope ends at Egghead.

## Config from the CLI

A few commands handle common edits without opening the file:

```bash
egghead config path                     # print resolved config path
egghead config set default_model anthropic/claude-sonnet-4-6
egghead config set web.port 4001
egghead config set web.bind 0.0.0.0     # expose externally
```

`set` edits the YAML in place, preserving comments and whitespace
where possible.

## Logs and state

Not in `config.yml` — these follow XDG conventions:

- **Logs:** `$XDG_STATE_HOME/egghead/egghead.log`, typically
  `~/.local/state/egghead/egghead.log`. `egghead logs` tails it.
- **Runtime state** (default room, etc.): same directory.
- **Index:** under your `records_dir` at `.egghead/index.db` —
  derived, safe to delete.

## Degraded mode

Start Egghead with no providers configured and no env vars set, and
the system still comes up. The record store, search, MCP record
tools, and the TUI records browser all work. The things that need
an actual LLM — `Egghead.chat`, `Egghead.prompt`, `Egghead.consult`,
agent activation in rooms — return a clean error telling you what's
missing.

This is deliberate. A node without credentials is still a useful
node: a searchable graph of your notes, a Markdown editor with
backlinks, an MCP server with eight record-manipulation tools. Add
an API key and the collaboration layer wakes up.
