---
title: Configuration
section: Operations
weight: 36
summary: config.yml schema, XDG paths, environment-variable substitution, provider setup.
---

Egghead reads its configuration from a single YAML file. With no
configuration file and no environment variables set, the system
still comes up: record reading, search, the TUI records
browser, and the eight record-related MCP tools all work.
Anything that needs an LLM returns an error in that mode, but
the store and its index keep functioning.

## Where the file lives

Egghead resolves the configuration path in this order, taking
the first match:

1. `$EGGHEAD_CONFIG`, if set. The variable can point at a
   directory (Egghead reads `config.yml` inside) or directly at
   a `.yml` file.
2. `$XDG_CONFIG_HOME/egghead/config.yml`, when the variable is
   set.
3. `~/.config/egghead/config.yml` otherwise.

`egghead config path` prints the resolved path. When Egghead
writes the file (during `egghead init` or
`egghead config set`), it sets the file mode to `0600`, on the
assumption that API keys may end up inside.

## Precedence

Three layers determine an effective setting; the highest layer
that has a value wins:

1. Environment variables. Provider API keys
   (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and so on) are
   detected at startup and override anything in the config
   file.
2. The configuration file.
3. Built-in defaults.

The practical implication is that you can run Egghead with no
configuration file at all, and as long as your shell exports an
API key, the agent layer comes up. The configuration file is
for persistent, considered choices; the environment is for
credentials and per-session overrides.

## Schema

Every key is optional. A configuration file containing only
`default_model: anthropic/claude-sonnet-4-6` is a legal file.

```yaml
# Where records live. Default: ~/.egghead.
records_dir: ~/.egghead

# Drop-zone for portable skills outside the records directory.
# Default: ~/.agents/skills.
skills_dir: ~/.agents/skills

# Workspace ceiling for fs.* and proc.* grants.
# Optional; can be declared per-agent instead.
sandbox: ~/Work

# LLM providers. Multiple entries permitted (custom base URLs).
llm:
  - provider: anthropic
    api_key: "{env:ANTHROPIC_API_KEY}"

  - provider: openai
    api_key: "{env:OPENAI_API_KEY}"

  # Custom OpenAI-compatible endpoint. The `name:` field
  # distinguishes it from the default openai entry.
  - provider: openai
    name: together
    base_url: https://api.together.xyz/v1
    api_key: "{env:TOGETHER_API_KEY}"

# Default model for new agents and 1:1 prompts.
default_model: anthropic/claude-sonnet-4-6

# Default chat-room id. Created on demand.
default_room: default

# Format for newly created records — `markdown` (the default) or `org`.
# Existing files keep their on-disk format regardless. Setting this to
# `org` only changes the extension and writer used when Egghead creates
# a new file. See [Org-mode]({{< ref "org-mode" >}}).
default_format: markdown

# Web server and MCP HTTP endpoint.
web:
  port: 4000
  host: localhost
  bind: 127.0.0.1

# External MCP servers your agents can reach.
mcp_servers:
  - name: playwright
    transport: stdio
    command: npx @playwright/mcp@latest
    env:
      PLAYWRIGHT_HEADLESS: "1"
    requires:
      - net.get: { hosts: ["*"] }
      - net.post: { hosts: ["*"] }
```

## `{env:VAR}` substitution

Anywhere a string value could be sensitive, you can write
`{env:VAR_NAME}` and Egghead resolves it from the environment
at load time. The literal string sits in the file; the secret
itself stays in the environment. This pattern lets you commit
your configuration to version control without committing your
API keys with it.

```yaml
llm:
  - provider: anthropic
    api_key: "{env:ANTHROPIC_API_KEY}"
```

## Auto-detected providers

If the `llm:` section is empty (or the configuration file does
not exist at all), Egghead checks for these environment
variables at startup and registers the corresponding providers
automatically:

| Provider     | Environment variable(s)                |
|--------------|----------------------------------------|
| `anthropic`  | `ANTHROPIC_API_KEY`                    |
| `openai`     | `OPENAI_API_KEY`                       |
| `google`     | `GOOGLE_API_KEY` or `GEMINI_API_KEY`   |
| `xai`        | `XAI_API_KEY`                          |
| `groq`       | `GROQ_API_KEY`                         |
| `deepseek`   | `DEEPSEEK_API_KEY`                     |
| `mistral`    | `MISTRAL_API_KEY`                      |
| `openrouter` | `OPENROUTER_API_KEY`                   |

Several of these speak OpenAI-compatible APIs (`xai`, `groq`,
`deepseek`, `mistral`, `openrouter`, plus local runners
`ollama` and `lmstudio`). Egghead ships presets covering the
right `base_url` for each, so you can drop the provider name
into `llm:` without spelling out the URL.

## Model resolution

Models are written in `provider/model` form:

- `anthropic/claude-sonnet-4-6`
- `openai/gpt-4o`
- `google/gemini-2.0-flash`

A bare model name resolves where the prefix is unambiguous —
`claude-*` infers `anthropic`, `gpt-*` infers `openai`,
`gemini-*` infers `google`. For the ambiguous cases, prefix
the provider explicitly.

`egghead llm models` prints what each configured provider
reports.

## The web section

The web server hosts the records browser, the chat-room UI,
and the MCP HTTP endpoint at `/mcp` — all on the same port.

| Key        | Default     | Effect |
|------------|-------------|--------|
| `web.port` | `4000`      | TCP port the server listens on. |
| `web.host` | `localhost` | Host used in generated absolute URLs. |
| `web.bind` | `127.0.0.1` | Listen address. Set to `0.0.0.0` to bind every interface. |

The default bind is loopback because Egghead does no
authentication of its own and a network-reachable endpoint
without authentication exposes the entire records store. See
[Running a node]({{< ref "running-a-node" >}}) before binding
beyond loopback.

## External MCP servers

`mcp_servers:` connects Egghead, as an MCP client, to other
servers. Their tools become available to agents that hold the
declared `requires:` capabilities.

```yaml
mcp_servers:
  - name: playwright
    transport: stdio
    command: npx @playwright/mcp@latest
    requires:
      - net.get: { hosts: ["*"] }
```

The `requires:` block uses the same capability grammar as an
agent's own grants (see
[Capabilities]({{< ref "capabilities" >}})). At invocation
time, Egghead checks the asking agent's capabilities against
`requires:` and filters out any tool the agent cannot use.
The remote MCP server itself is never asked to enforce
anything; the scope ends inside Egghead.

## CLI shortcuts

A few commands handle common edits without opening the file:

```bash
egghead config path                     # print the resolved path
egghead config set default_model anthropic/claude-sonnet-4-6
egghead config set web.port 4001
egghead config set web.bind 0.0.0.0
egghead llm list                        # configured providers
egghead llm add                         # interactive provider setup
egghead llm test <provider>             # round-trip a small request
egghead llm models                      # list available models
```

`egghead config set` edits the YAML in place, preserving
comments and whitespace where it can.

## State and logs

These do not live in `config.yml`:

- The application log is at
  `$XDG_STATE_HOME/egghead/egghead.log`, which is typically
  `~/.local/state/egghead/egghead.log`. `egghead logs` tails
  it.
- The search index is at
  `<records_dir>/.egghead/index.db`. The index is derived
  from your records and is rebuilt automatically on start if
  it is missing.

## Running without an LLM

With no provider configured and no API key in the environment,
the agent layer returns errors and the rest of the system
operates normally. Specifically:
`Egghead.search/2`, `Egghead.get_record/1`,
`Egghead.list_records/0` and the corresponding MCP tools
(eight of the fifteen) work; the TUI's records mode works;
`Egghead.chat/2`, `Egghead.prompt/3`, `Egghead.consult/2`,
and any agent activation in a room return
`{:error, :no_providers}`.

This is deliberate. Egghead is useful as a searchable,
linkable Markdown notebook on its own, even before any agent
is involved. Add an API key to the environment or to the
configuration file, restart, and the agent layer wakes up.
