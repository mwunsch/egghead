---
title: Running a node
section: Operations
weight: 38
summary: egghead serve as a long-lived process. Binding, exposure, secrets, logs, backup, process supervision.
---

A running Egghead node is a single operating-system process,
either `egghead serve` or the TUI. That one process houses the
records index, every running agent, every live chat room, the
web UI, and the MCP HTTP endpoint, all listening on a single
port. There is no cluster story, no separate database service,
and no message queue in the way. If you stop the process,
nothing keeps running; if you start it, everything comes back.

This guide walks through the operational shape of that process:
starting and stopping the server, exposing it safely to
something other than your own laptop, where logs go, what to
back up, and what to put in front of it for production use.

## Starting the server

```bash
egghead serve
```

The command starts the web UI, the file watcher, the agent
layer, and the HTTP listener, all in one process. It runs in
the foreground and logs to standard output, so you can see what
is happening; it blocks until you terminate it. When you are
ready to run Egghead under a process manager, the command stays
the same.

A couple of optional flags are worth knowing:

- `--port <n>` overrides `web.port` from the configuration
  file for this invocation.
- `--config <path>` points at a different configuration file
  for this invocation, leaving the default file untouched.

The TUI (`egghead` with no subcommand) runs the same supervision
tree, but renders to the terminal instead of serving HTTP. The
TUI redirects logs to a file, because its terminal output is
the alt-screen renderer and any stray log line would corrupt
the display.

## Bind and exposure

The relevant configuration is in the `web:` section:

```yaml
web:
  port: 4000
  host: localhost
  bind: 127.0.0.1
```

The default bind is `127.0.0.1`, which means the server only
accepts connections from the local machine. This is almost
always the right choice. Egghead does no authentication of its
own — the HTTP MCP transport and the web UI both grant full
node authority to anyone who can connect — so a
network-reachable endpoint without authentication is, in
effect, an unauthenticated read/write API for your records
store and your agents.

There are two safe ways to deploy:

1. **Loopback only.** Keep the default `bind: 127.0.0.1` and
   reach the server from the same machine at
   `http://127.0.0.1:4000`. This is the right shape for a
   personal laptop or a developer machine.
2. **Loopback plus a reverse proxy.** Keep the default bind,
   then run nginx, Caddy, or similar on a public interface,
   handling TLS and authentication. The proxy forwards `/`
   and `/mcp` to `127.0.0.1:4000`, and Egghead never sees a
   request the proxy did not authenticate. This is the right
   shape for a node running on a VPS or a homelab box that
   anyone outside the LAN should be able to reach.

There is exactly one safe way to bind `0.0.0.0` directly,
without a reverse proxy in front: when every network interface
the server is listening on is itself protected. If you put the
machine on a Tailscale tailnet, only members of your tailnet
can connect to it. If you put it on a private VPC subnet, only
resources inside the VPC can connect. In both cases the network
itself has done the authentication for you, and Egghead's lack
of built-in auth is no longer a problem.

If your machine has a public IP and you bind `0.0.0.0` without
either a reverse proxy or a network like the ones above, anyone
on the internet can reach the endpoint, and because Egghead
does no authentication on its own, they can read every record
and prompt every agent. This is the failure mode that
"unauthenticated public web app" usually implies, plus the
uncomfortable detail that your agents may be configured to
write files, run shell commands, or hit external APIs on your
behalf. Don't bind `0.0.0.0` to a public interface without
authentication in front.

## BEAM distribution and remote attach

Every running egghead process is an Erlang node. When you launch a
second egghead command from the same machine — `egghead`, `egghead mcp`,
`egghead rooms` — it discovers the long-running `egghead serve` over
the local Erlang Port Mapper Daemon (epmd) on TCP 4369, connects, and
becomes a client of that supervision tree. You see one set of agents,
one set of rooms, one record store. Same-host attach is zero-config:
no flag, no env var, no entry in `config.yml`. The cookie is whatever
OTP wrote to `~/.erlang.cookie` the first time a named node started.

This is the cluster-internal interface — distinct from the HTTP and
MCP surfaces above, which are the *public* interfaces a reverse proxy
sits in front of. Distribution is what makes the TUI feel like a thin
client over `egghead serve` instead of a separate program: same
processes, same PubSub, same coordinator. [Why Elixir/OTP]({{< ref
"why-elixir-otp" >}}) goes into why this is a runtime primitive rather
than a feature we built; the short version is that Ericsson designed
distribution into the BEAM in the 1980s so a phone-switching cluster
could route calls between physical machines, and Egghead inherits the
result. The
[Distributed Erlang reference](https://www.erlang.org/doc/system/distributed.html)
and the
[epmd(1) man page](https://www.erlang.org/doc/apps/erts/epmd_cmd.html)
are the authoritative documentation for the underlying mechanism.

The same mechanism extends to a LAN or a tailnet. The piece that
changes is the hostname.

### Same-host (default)

Nothing to configure. `egghead serve` registers as
`egghead_server@localhost` with epmd. Other commands on the same
machine find it automatically.

### Cross-host

On the host that runs the server, set `server.host` in `config.yml`:

```yaml
server:
  host: orca.tailnet.ts.net
  port_range: [9100, 9105]    # optional; pins the dist port range
```

`server.host` switches the BEAM to longnames and registers as
`egghead_server@orca.tailnet.ts.net`. `server.port_range` pins the
distribution listener's port range so a single firewall rule (plus
epmd on 4369) covers it.

On any other host on the same network, point at the server with the
`EGGHEAD_SERVER` environment variable or the `--server` flag:

```bash
EGGHEAD_SERVER=orca.tailnet.ts.net egghead         # TUI
EGGHEAD_SERVER=orca.tailnet.ts.net egghead mcp     # MCP stdio
egghead --server orca.tailnet.ts.net rooms list    # one-off
```

The client probes epmd on the named host, finds `egghead_server`,
and joins the cluster. From then on, the TUI and MCP behave exactly
as they would same-host — agents, rooms, transcripts, record
mutations all flow over distribution.

### Sharing the cookie

Both hosts must read the same `~/.erlang.cookie`. Egghead does not
manage the cookie file; OTP does. To copy it:

```bash
# on the server host
egghead config show-cookie
```

Paste the output into `~/.erlang.cookie` on each peer host, then
`chmod 0400 ~/.erlang.cookie`. `egghead doctor` flags a missing
cookie when `server.host` or `EGGHEAD_SERVER` is set.

### Firewall

Distribution needs two things reachable on the chosen network
interface:

- **epmd**: TCP 4369 (the port mapper)
- **dist range**: whatever you set as `port_range`, default 9100–9105
  if you pinned one. Without `port_range`, the dist listener picks an
  ephemeral port and you have to allow the full ephemeral range.

Pin the range. It's a one-line change to the firewall.

### Security

BEAM distribution traffic is **unencrypted on the wire**, and the
shared cookie is weak authentication. This is fine on a tailnet, a
private VPC, or a LAN you trust. It is **not** safe on the public
internet. Never expose epmd or the dist port range to a public
interface.

The clean cross-host story is: the network you're using is itself
the security boundary. Tailscale, Nebula, WireGuard, ZeroTier, a
private VPC subnet — any of these handle authentication and
encryption for you, and Egghead's distribution layer rides on top.
For deployments outside that envelope, expose only HTTP + MCP through
a reverse proxy, the same way you would any other unauthenticated
HTTP service.

## Secrets

When you are binding beyond loopback, set `SECRET_KEY_BASE`
in the environment:

```bash
export SECRET_KEY_BASE=$(openssl rand -base64 48)
egghead serve
```

`SECRET_KEY_BASE` is the secret the web server uses to sign
session cookies and other server-side state. Without it, the
server generates a per-process key at startup and warns. That
is acceptable for localhost, where session continuity across
restarts is not security-critical, but it is not acceptable
for anything that crosses the network. Persist the value in
the environment rather than in `config.yml`. The
`{env:SECRET_KEY_BASE}` substitution lets you reference it
from the configuration file without storing the secret there.

## Logs

By default, the application log lives at
`~/.local/state/egghead/egghead.log` (Egghead respects
`$XDG_STATE_HOME` if set). The log routing depends on which
command you ran:

| Mode       | Used by                             |
|------------|-------------------------------------|
| `:console` | `egghead serve`, `iex -S mix`        |
| `:file`    | the TUI and most CLI commands        |
| `:silent`  | `egghead mcp` (because stdout carries the JSON-RPC protocol) |

To follow the log:

```bash
egghead logs            # tail -f
egghead logs -n 200     # start with the last 200 lines
```

## State and persistence

The records directory is the source of truth. Everything else
is derived from it:

| Thing                | Location                              | Rebuild if lost |
|----------------------|---------------------------------------|-----------------|
| Records              | `<records_dir>/*.md`                  | No, this is your data. |
| Search index         | `<records_dir>/.egghead/index.db`     | Yes, from records. |
| Agent processes      | RAM only                              | Yes, from `class: agent` records. |
| Live chat rooms      | RAM only                              | No — `/save` first. |
| Saved transcripts    | `class: transcript` records           | They are records. |

That table has practical implications worth naming.

Backup is `cp -r` or `rsync` against the records directory.
There is no database to dump and no migration script to run.
Whatever already keeps your Markdown notes safe — Git, iCloud,
a NAS, a cron job — is also what keeps your Egghead store
safe.

The search index is disposable. If you delete
`<records_dir>/.egghead/index.db`, Egghead rebuilds it on next
start; the rebuild takes longer than a normal startup but
nothing is lost.

Live rooms are not persistent. If you want a conversation to
survive a restart, save the transcript first. The default
`/drop` behavior auto-saves, so in practice you rarely have to
think about this.

## Version-controlling the records directory

Putting your records directory under Git turns every note,
every agent definition, and every saved transcript into a
diffable artifact with history:

```bash
cd ~/.egghead
git init
git add -A
git commit -m "initial"
```

A consequence of putting agent records under Git: widening an
agent's capabilities becomes a reviewable change. The diff
shows exactly which verbs were added or removed, and a code
review on a Git commit is the same review you would otherwise
have to do at runtime. This is the workflow Egghead's
authority model assumes.

The `.egghead/` subdirectory (index, runtime state) is safe
to add to `.gitignore`; it is rebuilt on any fresh checkout.

## Optional dependencies

| Platform | Package         | Purpose |
|----------|-----------------|---------|
| Linux    | `inotify-tools` | File watcher for record hot-reload. |
| Linux    | `bubblewrap`    | Sandbox backend for `fs.*` and `proc.*` grants. |
| macOS    | none            | FSEvents and `sandbox-exec` are native. |
| Windows  | not supported   | — |

`egghead doctor` checks both Linux dependencies and prints the
install one-liner for your package manager when one is
missing. Without `inotify-tools`, changes to records will not
hot-reload until the next start; without `bubblewrap`, agents
holding `fs.*` or `proc.*` grants run unsandboxed and Egghead
warns at startup.

Everything else is bundled in the binary. There is no BEAM or
Elixir runtime to install separately; Burrito-packaged
releases are self-contained.

## Keeping the server alive

`egghead serve` is a foreground process. It does not
daemonize itself, so use the system's process manager.

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

Then:

```bash
systemctl enable --now egghead
journalctl -u egghead -f
```

### launchd (macOS)

A LaunchAgent plist with
`ProgramArguments = ["/usr/local/bin/egghead", "serve"]` and
`KeepAlive = true`. Place the file in
`~/Library/LaunchAgents/` and run `launchctl load` against it.

### Graceful shutdown

```bash
kill $(pgrep -f 'egghead serve')
```

`SIGTERM` flushes the supervision tree and closes the records
store cleanly. The BEAM's interactive abort sequence
(`Ctrl-C`, then `a`) also works when you are running the
server in the foreground.

## Reverse proxy

A short Caddy example that handles TLS and basic auth in front
of an Egghead node bound to loopback:

```caddy
egghead.example.com {
  reverse_proxy 127.0.0.1:4000
  basicauth {
    you $2a$14$...
  }
}
```

The equivalent for nginx:

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

Set `web.host` in `config.yml` to the external hostname
(`egghead.example.com` in this example) so any absolute URLs
Egghead generates point at the proxy rather than at loopback.

## `egghead doctor`

Run `egghead doctor` whenever something looks off. It checks
that the configuration file parses, that the records directory
is present and writable, that the SQLite index is readable or
rebuildable, that each configured LLM provider responds to a
small probe, that every agent record passes frontmatter
validation, that the Linux file-watcher and sandbox
dependencies are installed, that the log file is writable,
and that the OpenTUI native module is available for the TUI.

`doctor` exits non-zero on failure and zero on pass-or-warning,
so it composes into shell scripts. It is safe to run against a
live node.

## Upgrading

Replace the binary, then restart the process. Records are
version-independent (they are plain Markdown), and the search
index is automatically rebuilt if the schema changed across
versions. The first start after an upgrade is sometimes
slower for that reason; nothing is lost.

GitHub Releases publishes binaries for macOS arm64 and Linux
x86_64 on every tag. The install script always points at the
latest release.

## Monitoring

Egghead does not yet expose Prometheus metrics or
OpenTelemetry traces. The log file is the observability
surface today; tail it through `egghead logs` or pipe it into
whatever log aggregator you already have (`journalctl`, Loki,
Vector, anything that reads files).

For multi-node deployments, the answer today is independent
per-node backups and per-node log shipping. There is no
cluster story, no shared state between nodes, and no built-in
mechanism for syncing one node's records to another's beyond
running Git on the records directory.

## See also

- [Configuration]({{< ref "configuration" >}}) covers the
  full schema of `config.yml`.
- [MCP server]({{< ref "mcp" >}}) covers exposing the tool
  surface, on either transport.
- [Capabilities]({{< ref "capabilities" >}}) covers what
  agents are allowed to do once running.
