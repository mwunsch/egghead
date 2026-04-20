---
title: Running a node
weight: 40
---

Egghead is designed to run as a single process on a single machine
— your laptop, a VPS, a home server. No distributed dance, no
Kubernetes manifest. A node is a `egghead serve` process (or the
TUI), a records directory, a config file, and whatever process
manager you choose to keep the thing alive.

This guide covers the operational shape: starting the server,
exposing it safely, tailing logs, backing up the store, and what to
check when something looks off.

## `egghead serve`

```bash
egghead serve
```

Starts the web UI, the MCP HTTP endpoint, the record store watcher,
the agent layer, and Phoenix's HTTP listener — all in one process,
on one port. Blocks in the foreground. Logs to stdout by default.

Optional flags:

- `--port <n>` — override the HTTP port from the command line.
- `--config <path>` — point at a different config file for this
  invocation.

The TUI (`egghead`) runs the same supervision tree but with a
terminal interface instead of the web frontend. Logs go to file
when the TUI is running — the alt-screen renderer would corrupt
stdout otherwise.

## Binding and exposure

Configuration lives in the `web:` section of `config.yml` (see the
[Configuration guide]({{< ref "configuration" >}})):

```yaml
web:
  port: 4000          # listen port
  host: localhost     # hostname in generated URLs
  bind: 127.0.0.1     # listen address
```

The default `bind: 127.0.0.1` means the server only accepts
connections from the local machine. This is almost always what you
want — the HTTP MCP transport and the web UI both grant full node
authority, and neither does any authentication on its own.

If you want to expose the node externally, you have two options and
only one of them is sound:

**The right way: reverse proxy.** Keep the Egghead bind at
`127.0.0.1:4000`. Run nginx, Caddy, or similar on the public
interface. Terminate TLS there. Put authentication (basic auth,
OAuth, mTLS, IP allow-list) in front of the proxy. Forward `/` and
`/mcp` through to `127.0.0.1:4000`.

**The wrong way: `bind: 0.0.0.0` with nothing in front.** An
Egghead node with no authentication listening on a public interface
is a fully-authorized MCP server anyone can hit. Don't.

If you're running on a trusted internal network (Tailscale, a
VPC with strict ingress), `bind: 0.0.0.0` is fine — the perimeter
is somewhere else. Know where your perimeter is.

## Secrets and sessions

When binding beyond loopback, set `SECRET_KEY_BASE` in the
environment:

```bash
export SECRET_KEY_BASE=$(openssl rand -base64 48)
egghead serve
```

This keys Phoenix's session cookies. Without it, Egghead warns at
startup and falls back to a generated-per-run key — usable for
localhost, not for anything that crosses the network.

Same rule as with API keys: keep it in the environment, not the
config file. The `{env:SECRET_KEY_BASE}` pattern works if you want
it referenced from config explicitly.

## Logs

By default, logs land at:

```
~/.local/state/egghead/egghead.log
```

Honoring `$XDG_STATE_HOME` when set. Three modes:

- `:console` — stdout. Used by `egghead serve` and `iex -S mix`.
- `:file` — redirect to the log file. Used by the TUI (stdout is
  the alt-screen renderer; logs would corrupt it) and by default
  for most CLI commands.
- `:silent` — to file, no console. Used by `egghead mcp` because
  MCP is JSON-RPC on stdout and any log noise would break the
  protocol.

Tail them:

```bash
egghead logs            # tail -f the log file
egghead logs -n 200     # start with the last 200 lines
```

## Persistence model

The records directory is the source of truth. Everything else is
derived:

| Thing                                | Where it is                     | Rebuild if lost? |
|--------------------------------------|----------------------------------|------------------|
| Records                              | `<records_dir>/*.md`             | No — this is data |
| Search index                         | `<records_dir>/.egghead/index.db` | Yes, from records |
| Agent processes                      | RAM only                         | Yes, from agent records |
| Live chat rooms                      | RAM only                         | No (save first)  |
| Saved transcripts                    | Records with `class: transcript` | They're records  |

The practical implications:

- **Backup = copy the records directory.** `rsync`, `git`, cloud
  sync, whatever you already use for Markdown. That's the whole
  backup strategy.
- **The index is disposable.** Delete
  `<records_dir>/.egghead/index.db` and the store rebuilds it on
  next start. First start takes longer; nothing is lost.
- **Live rooms are not persistent.** If you want a conversation to
  survive a node restart, `/save` it as a transcript first. Dropped
  rooms auto-save by default, so in practice you mostly don't need
  to think about it.

## Version-controlling the store

`git init` inside your records directory turns your knowledge graph
into a version-controlled artifact:

```bash
cd ~/.egghead
git init
git add -A
git commit -m "initial"
```

Commit regularly — the file-level diffs are readable, merge
conflicts on separate records are trivial, and you get history on
every note, every agent definition, every saved transcript. Widening
an agent's capabilities becomes a git-diffable change. An
accidentally-edited record becomes a `git restore` away from fixed.

The `.egghead/` subdirectory (index, state) is safe to `.gitignore`
— it'll be rebuilt on any fresh checkout.

## `egghead doctor`

Run before you dig into a problem:

```bash
egghead doctor
```

Checks:

- Config file exists and parses
- Records directory is present and writable
- The SQLite index is readable (or can be rebuilt)
- Each configured LLM provider responds to a lightweight probe
- Agent records pass frontmatter validation (unknown capabilities,
  bad scope keys, escalation risks; see the
  [Capabilities guide]({{< ref "capabilities" >}}))
- On Linux: `inotifywait` is installed (required for file watching)
- Log file is writable
- OpenTUI NIF is available for this platform (TUI feature)

Emits a summary of passes, warnings, and failures with suggested
fixes. Non-zero exit on failure, zero exit on pass-or-warning — so
it composes into scripts.

Doctor is idempotent and safe to run against a live node.

## Optional OS dependencies

| OS       | What you need             | Why                                    |
|----------|---------------------------|----------------------------------------|
| Linux    | `inotify-tools`           | File watcher for record hot-reload     |
| macOS    | Nothing                   | FSEvents is native                     |
| Windows  | Not supported yet         |                                        |

Without `inotify-tools`, changes to records require a manual restart
to pick up. `egghead doctor` flags the absence and prints the
install one-liner for your package manager.

Everything else is bundled in the binary — no runtime dependencies,
no BEAM installation required. Burrito-packaged releases are
self-contained.

## Keeping it alive

`egghead serve` is a foreground process with no built-in
daemonization. Use your system's process manager.

### systemd

```ini
# /etc/systemd/system/egghead.service
[Unit]
Description=Egghead
After=network.target

[Service]
Type=simple
User=egghead
Environment="ANTHROPIC_API_KEY=..."
Environment="SECRET_KEY_BASE=..."
ExecStart=/usr/local/bin/egghead serve
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
systemctl enable --now egghead
systemctl status egghead
journalctl -u egghead -f
```

### launchd (macOS)

A `LaunchAgent` plist with `ProgramArguments = ["/usr/local/bin/egghead", "serve"]`
and `KeepAlive = true`. Put it in `~/Library/LaunchAgents/` and
`launchctl load` it.

### tmux / screen

For a dev box: `tmux new -s egghead "egghead serve"` and detach.
Not production-grade, but fine for "I'm iterating and want this up
without a terminal in the foreground."

### Graceful shutdown

`SIGTERM` cleanly flushes the supervision tree and closes the
record store:

```bash
kill $(pgrep -f 'egghead serve')
```

The BEAM's abort menu (Ctrl-C in an interactive session, then `a`)
also works in the foreground.

## Reverse proxy example

Caddy is probably the shortest path:

```caddy
egghead.example.com {
  reverse_proxy 127.0.0.1:4000
  basicauth {
    you $2a$14$...
  }
}
```

nginx:

```nginx
server {
  listen 443 ssl http2;
  server_name egghead.example.com;

  ssl_certificate /etc/letsencrypt/live/egghead.example.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/egghead.example.com/privkey.pem;

  auth_basic "Egghead";
  auth_basic_user_file /etc/nginx/htpasswd;

  location / {
    proxy_pass http://127.0.0.1:4000;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
  }
}
```

Set `web.host` in config.yml to the external hostname
(`egghead.example.com`) so generated links point at the proxy, not
loopback.

## Degraded mode

If no LLM provider is configured and no API key env vars are set,
the node still comes up. What you get:

- Records: search, read, write, traversal — all working
- The web UI: full records browser, no chat
- MCP tools: record-manipulation tools all functional; agent- and
  consult-related tools return "no providers configured"
- The TUI records mode: unchanged

This is the "knowledge store with no agents" configuration — useful
as a baseline, deliberately supported. Add a key to the config or
the environment and the agent layer wakes up without a restart.

## Upgrading

Replace the binary, restart the process. Records are version-
independent (plain Markdown). The index may get rebuilt if the
schema changed across versions — expect a slower first start in
that case; nothing is lost.

If you're tracking releases, the GitHub releases page publishes
binaries for macOS ARM64 and Linux x86_64 on every tag. See the
installation docs for the install script.

## Monitoring

Egghead doesn't ship Prometheus metrics or structured telemetry yet.
For now: the log file is the observability surface. `egghead logs`
and a log aggregator (journalctl, file-based Loki, whatever you
already have) will get you the visibility you need for a single
node.

If you're running multiple nodes, the right move today is
independent per-node backups and per-node log shipping. There is no
cluster story.

## See also

- [Configuration]({{< ref "configuration" >}}) — what goes in
  `config.yml`, how env vars interact
- [MCP server]({{< ref "mcp" >}}) — exposing the tool surface, both
  transports
- [Capabilities]({{< ref "capabilities" >}}) — what agents are
  allowed to do once they're running
