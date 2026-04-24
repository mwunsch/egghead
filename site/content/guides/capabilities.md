---
title: Capabilities
weight: 20
---

Egghead [agents]({{< ref "agents" >}}) are participants in your
record store, not owners of it. What any particular agent is
*allowed* to do — read records, create them, hit the network, run
shell commands — is controlled by its **capabilities**: a
per-agent, record-declared, parameter-scoped list of grants.

Capabilities do three jobs at once. The obvious one is security:
least privilege prevents a compromised or confused agent from
doing damage it shouldn't be able to. The second is separation of
duties: no single agent can both propose a modification and approve
it, because the capability to do each is held by different roles
(standard guidance from the
[CERT guide to insider threat](https://resources.sei.cmu.edu/library/asset-view.cfm?assetid=540644),
ported down from human systems to agent systems). The third is
less obvious but load-bearing for a multi-agent design:
**capabilities make roles structural rather than prompt-level**.
If one role is "read-only" and another is "write-with-peer-review,"
those roles can't flip to match each other under majority pressure
— the grants are enforced by the runtime, not by the system
prompt. The [conformity literature]({{< ref "research-influences" >}})
shows that persona differentiation in prompts is a weak lever;
capability-scoped authority is a stronger one because an agent
literally cannot perform a peer's role even if it wanted to agree
with them.

Enforcement is kernel-backed: `fs.*` and `proc.*` grants run inside
an OS sandbox (`sandbox-exec` on macOS, `bwrap` on Linux) derived
from the agent's `sandbox:` declaration, so a compromised tool cannot
escape the fence. Capabilities are the **pledge** — what verbs an
agent holds — and the sandbox is the **unveil** — where those verbs
can have effect. The two halves are kept separate by design, and
authored separately in the frontmatter.

This guide is for anyone running an Egghead node. It covers what to
write in an agent's frontmatter, how grants compose, where the sandbox
fence comes from, what the CLI and `egghead doctor` will catch, and
how agents delegate authority to each other.

## The shape of a grant

Every capability is a `resource.verb` pair, optionally with a scope.

```yaml
sandbox: ~/projects/foo
capabilities:
  - records.read
  - records.update:
      classes: [deliberation, inbox]
  - net.get:
      hosts: ["*.github.com", "api.anthropic.com"]
  - proc.exec:
      in: ~/projects/foo
      cmds: [rg, jq, git]
```

Five resource families cover the whole surface:

| Resource  | What it governs                              |
|-----------|----------------------------------------------|
| `records` | Content records — read, create, update, delete |
| `agent`   | Agent records specifically — create, update, delete, **grant** |
| `fs`      | Files *outside* the record store             |
| `net`     | Outbound HTTP — `get`, `post`, `put`, `delete` |
| `proc`    | Spawning subprocesses — `exec` (argv-style), `eval` (bash pipelines) |

The split between `records` and `agent` is load-bearing: a call
targeting an agent record always requires an `agent.*` grant, never a
`records.*` grant, regardless of scope. An agent holding only
`records.update` cannot edit another agent's configuration — by
design.

## Risk tiers

Every capability in the catalog carries a risk level. The CLI, the
agent wizard, and `egghead doctor` all sort and color output by risk.

| Risk    | Examples                                             |
|---------|------------------------------------------------------|
| **Low**    | `records.read`, `records.create`                   |
| **Medium** | `records.update`, `fs.read`, `net.get`, `agent.update` |
| **High**   | `records.delete`, `fs.write`, `fs.delete`, `net.post`/`put`/`delete`, `proc.exec`, `proc.eval`, `agent.delete`, `agent.grant` |

Low-risk capabilities are the ergonomic default. Medium- and high-risk
capabilities should be scoped.

## Where agents can go — the sandbox

A capability tells you *what verb* an agent holds. A **sandbox** tells
you *where* that verb can have effect. It's the second coordinate in
the authority system, and it's enforced by the kernel — not the LLM,
not the Elixir matcher, not the tool implementation. A compromised
binary running under an allowed `proc.exec` can't escape the fence
even if it tries. On macOS the fence is `sandbox-exec`; on Linux it's
`bwrap` (bubblewrap). `egghead doctor` checks that the backend for
your platform is available.

The sandbox root can be declared at three levels, and all three
compose through a hoist chain:

1. **Config level** — `sandbox:` in `~/.config/egghead/config.yml`.
   The global ceiling. No agent, no skill, no MCP tool can escape
   this path.
2. **Agent level** — `sandbox:` in an agent record's frontmatter.
   Narrower than config; must resolve inside it.
3. **Grant level** — `in:` on a specific capability scope. Narrower
   still; must resolve inside agent.

Deeper declarations win, missing ones inherit from above, and **each
level can only narrow**. An agent declaring `sandbox: /etc` under a
config with `sandbox: ~/Work` gets clamped to the config ceiling at
load time with a loud warning — the DSL rule is "sandboxes only
narrow," and widening attempts don't succeed silently.

### The one-line config change

If you set `sandbox: ~/Work` in config, every existing agent's
external grants become functional inside `~/Work` without touching
any agent record:

```yaml
# ~/.config/egghead/config.yml
records_dir: ~/.egghead
sandbox: ~/Work
```

A bare `fs.read` or `proc.exec` grant anywhere hoists the config root
into its effective `in:` and starts working. This is the intended
ergonomic payoff of the hoist model — one line, machine-wide fence.

### Top-level `sandbox:` as sugar

In an agent record, `sandbox:` is a shortcut that expands into three
grants, all rooted at the declared path:

```yaml
---
id: agents/scout
class: agent
sandbox: ~/projects/foo
capabilities: [records.read]
---
```

Expands at load time to:

```yaml
capabilities:
  - records.read
  - fs.read:   { in: ~/projects/foo }
  - fs.write:  { in: ~/projects/foo }
  - proc.exec: { in: ~/projects/foo }
```

`proc.eval` is **not** in the sugar — its risk profile requires
explicit opt-in. `net.*` is likewise excluded — network is an
orthogonal axis the user declares separately via `net.get`/`net.post`.

The sugar works the same way `access:` does: a load-time expansion
that joins the union of `access:` + `sandbox:` + explicit
`capabilities:` and dedupes. Nothing downstream sees the shortcut.
When you `grant` or `revoke` on an agent that uses `sandbox:`, the
CLI dissolves it: the record rewrites with the explicit expanded
capabilities and removes the `sandbox:` key, so the frontmatter on
disk always reflects the agent's real authority.

### Per-grant `in:` + relative `paths:`

For cases where the three-grant sugar is too broad, write the
capabilities explicitly and use `in:` on each:

```yaml
sandbox: ~/Work/egghead
capabilities:
  - records.read
  - fs.read:   { in: ~/Work/egghead, paths: [./lib, ./test] }
  - fs.write:  { in: ~/Work/egghead, paths: [./lib] }
  - proc.exec: { in: ~/Work/egghead, cmds: [mix, git, rg] }
  - proc.eval: { in: ~/Work/egghead }
```

Rules to know:

- **`in:`** — a single absolute-or-`~`-prefixed path. The ceiling for
  this grant.
- **`paths:`** — optional list of refinements. Bare names (`lib`) and
  `./`-prefixed (`./lib`) resolve relative to `in:`. Absolute paths
  in `paths:` are allowed only if they're already inside `in:`.
- **No escape** — `..` entries that would escape `in:`, or absolute
  paths outside `in:`, are rejected at parse time with a clear error.
  Never a silent trim, never a runtime surprise.
- **`proc.eval` takes only `in:`** — no `cmds:` / `patterns:`. A
  free-form shell string can't be meaningfully argv-matched; the
  sandbox fence is the whole enforcement, and that's only tenable
  because the fence is kernel-level.

### When a sandbox is required

External grants (`fs.*`, `proc.*`) must have a hoistable `in:` by the
time they're checked. If all three levels are empty, the grant stays
inert — `egghead doctor` flags this with an actionable message
naming the dangling grants and the fix ("add `sandbox:` to the agent
record, or to `~/.config/egghead/config.yml`"). Network grants use
`hosts:`, not `in:`, so they're not affected by this rule.

## Bare vs scoped — know the difference

The bare form (`- net.get` on its own line) and the scoped form
(`- net.get: { hosts: [...] }`) mean different things depending on the
resource family.

**Internal resources** (`records.*`, `agent.*`) default bare-to-universe:

```yaml
- records.read        # read any record — fine
- records.update      # update any record — probably too wide
```

**External resources** (`net.*`, `fs.*`, `proc.*`) default
bare-to-empty — a bare grant is inert until scoped:

```yaml
- net.get             # inert: no hosts, no fetches allowed
- net.get:            # useful: explicitly allow any host
    hosts: ["*"]
```

For `fs.*` and `proc.*`, the scope that activates the grant is the
`in:` key — the sandbox root. A bare `fs.read` is inert until it has
an `in:`, either written on the grant itself or inherited from the
agent's `sandbox:` (see the [sandbox section](#where-agents-can-go-the-sandbox)).
Explicit `paths:` / `cmds:` / `patterns:` narrow further within `in:`.

The `"*"` entry on `net.get` hosts is a valid, auditable declaration
of "any host." It is different from the bare form and different from
omitting the grant entirely. The rule is there so no agent silently
ends up with unrestricted net or filesystem access.

## Allow-lists only, no wildcards by default

A few rules worth internalizing:

- **No NOT-syntax.** You cannot say "any host except these." The list
  is the review.
- **Allow-lists union when duplicated.** Two `net.get:` entries with
  different hosts merge additively.
- **Unknown capability names** are logged and ignored (forward-compat
  for skills referencing future capabilities). Typos *will* bite you
  silently — see the `egghead doctor` section below.

## Declaring grants in an agent record

An agent is just a record with `class: agent`. The body is its system
prompt; the frontmatter is its identity and authority.

```yaml
---
id: agents/scout
class: agent
model: anthropic/claude-sonnet-4-6
sandbox: ~/Work/egghead
capabilities:
  - records.read
  - records.create
  - records.update
  - net.get:
      hosts: ["*"]
  - net.post:
      hosts: ["*.parallel.ai"]
---

# Scout

You are Scout. You find connections across domains...
```

Scout holds the records verbs, the two network verbs, and — via the
`sandbox:` sugar — `fs.read`, `fs.write`, and `proc.exec` all rooted
at `~/Work/egghead`. The three external verbs the sandbox implies
are enough to read and edit files in the workspace and run commands
against them. To add shell pipelines, Scout would append `- proc.eval:
{ in: ~/Work/egghead }` explicitly; the sugar doesn't include it.

Capabilities are inert until the record is loaded. Widening them is a
**frontmatter edit** — a human act, auditable via git if your records
directory is version-controlled. There is no "always allow" prompt at
call time. This is intentional: the ratchet is the review.

### Useful by default

An agent record with no `capabilities:` key at all — and no `access:`
either, introduced below — loads with `records.read` as its only
grant. The principle: a fresh agent can inspect the store (find other
records, cite prior work), but nothing else. That's enough to be
useful in a room without being dangerous.

A zero-authority agent takes an explicit declaration — `capabilities: []`
and the load-time default is suppressed. The agent loads, shows up
in rosters, and can't do anything but talk. Useful occasionally (a
persona whose only job is to react in prose), but it's the deliberate
case, not the default.

### The `access:` shortcut

For the common `records.*` bundles, `access:` is a chmod-flavored
shorthand. Three values, nothing else:

| `access:` | Expands to                                              |
|-----------|---------------------------------------------------------|
| `r`       | `records.read`                                          |
| `w`       | `records.create`, `records.update`                      |
| `rw`      | `records.read`, `records.create`, `records.update`      |

```yaml
---
id: agents/scribe
class: agent
model: anthropic/claude-haiku-4-5
access: rw
---

# Scribe

You are Scribe. You write down what gets said...
```

Three things to know about it:

**It's sugar, not a new primitive.** At load time, `access:` is
expanded into real capability grants before anything else sees it.
The catalog, the attenuation check, the denial renderer — all of
them work with the expanded form. Nothing downstream knows the
shortcut exists.

**It unions with explicit `capabilities:`.** Write both, they combine
(deduped). The shortcut covers the records family; everything else —
scoped grants, external resources, agent verbs — still goes through
the full `capabilities:` list.

```yaml
access: r
capabilities:
  - net.get:
      hosts: ["api.github.com"]
```

**`records.delete` is deliberately excluded.** The catalog flags
deletion `:high` risk; shortcuts should never bundle risky verbs.
If you want a destructive agent, write `capabilities: [records.delete]`
explicitly — the extra keystrokes are the review.

A `w` without `r` is not a mistake. Write-blind agents — drop-boxes,
ingestion workers, crash reporters, producer-only pipelines — are a
real pattern, not a typo. Unix `w` on a directory has meant "can add
entries without reading the listing" since the 1970s. An agent that
can file reports but can't see other agents' reports is a
compartmentalization boundary, not a broken configuration.

`access:` and `sandbox:` are siblings — same shape, same dissolve
behavior on mutation. `access:` is sugar for the records-family
verbs; `sandbox:` is sugar for the workspace-bound external verbs.
You can use both in the same record; they union at load time:

```yaml
access: r               # records.read
sandbox: ~/projects/foo # fs.read + fs.write + proc.exec, all in: ~/projects/foo
capabilities:
  - net.get:
      hosts: ["api.github.com"]
```

## Attenuation — how agents grant other agents

The heaviest capability in the catalog is `agent.grant`. An agent that
holds it can write the `capabilities:` or `access:` field on other
agent records (through `create_record` or `update_record`). Both keys
route through the same check: `access:` is expanded into its
capability set first, unioned with any explicit `capabilities:` list,
and the *union* is what attenuation validates. The shortcut cannot be
used to slip a grant past the granter's authority.

Two rules keep this from turning into a capability escape:

**Self-modification is always denied.** An agent cannot use
`agent.grant` to widen itself, regardless of which grants it holds.
Full stop.

**Grants must be subsets.** The proposed capabilities must be ⊆ the
granter's own. Scope narrows, too: if the granter holds
`net.get{hosts: ["*.github.com"]}`, it can only pass on `net.get`
scoped to `github.com` or narrower.

If either rule is violated, the denial surfaces in three places: the
tool result the LLM sees (so it can course-correct), the room
transcript (rendered as an amber guardrail event), and the log.

## The CLI

Three commands cover day-to-day capability management:

```bash
egghead agents capabilities <agent-id>     # show held grants, sorted by risk
egghead agents grant <agent-id> <spec>     # widen — confirmation + audit log
egghead agents revoke <agent-id> <spec>    # narrow — no confirmation
```

The spec grammar matches the yaml shape in compact form:

```bash
egghead agents grant scout 'net.get{hosts=[*.github.com,api.anthropic.com]}'
egghead agents grant scout 'proc.exec{in=~/Work,cmds=[rg,jq]}'
egghead agents revoke scout records.update
```

`egghead agents grant <agent-id>` with no spec opens an interactive
picker over the catalog, sorted low-risk first.

### Grant, revoke, and the shortcuts

When you `grant` or `revoke` on an agent declared with `access:` or
`sandbox:`, the CLI **dissolves the shortcut**: the record is
rewritten with an explicit `capabilities:` list covering the unified
set (shortcuts expanded, plus whatever was already there, plus or
minus your change) and both `access:` and `sandbox:` keys are
removed. The contract is that the frontmatter on disk always
reflects the agent's real authority — you never see `access: rw` or
`sandbox: ~/foo` sitting next to an out-of-sync `capabilities:` list.

Shortcut-only agents that you don't touch with tooling keep their
shorthand indefinitely. The dissolution fires only when you mutate.
Agents with no declared capabilities at all (relying on the default
`records.read`) also get the default materialized into their
explicit list on first grant, so the grant can't silently drop the
default authority.

The same dissolution applies when agents grant each other via
`create_record` / `update_record` — a write that touches
`capabilities:`, `access:`, or `sandbox:` on an agent record always
lands as explicit `capabilities:` with neither shortcut key. This
also closes the escalation hole where an agent with `agent.update`
(but not `agent.grant`) might otherwise write `access: rw` or a
broader `sandbox:` to widen another agent silently.

## The built-in Index agent

Every Egghead install ships with a built-in **Index** agent so a fresh
install always has someone to talk to. Its defaults are narrow on
purpose (`records.read`, `records.create`) — enough to be useful,
nowhere near enough to reshape the record store on its own.

You widen Index the same way you widen any agent: by dropping a
record with `id: index` into your store.

```yaml
---
id: index
class: agent
model: anthropic/claude-sonnet-4-6
capabilities:
  - records.read
  - records.create
  - agent.create
  - agent.grant
---

You are Index, the record store agent...
```

The moment that record exists, the built-in default steps aside and
yours runs instead. Attenuation still applies: whatever grants this
record declares, it can only re-grant subsets to agents it spawns.

## What `egghead doctor` checks

`egghead doctor` iterates every record with `class: agent` and flags:

- **Unknown capability names.** `records.reed` → "did you mean
  `records.read`?" Uses string-distance matching, so close typos are
  caught.
- **Unknown scope keys.** `fs.write: { pathz: ["*"] }` → "did you mean
  `paths`?"
- **Wrong scope value types.** Scope keys expect either a string or a
  list of strings; anything else is flagged.
- **Escalation risks.** An `fs.write` or `fs.delete` whose `paths`
  scope covers your `records_dir` gets a warning — the capability
  model can be bypassed by writing records directly. Same for
  `proc.exec` / `proc.eval` granted with no `in:`, no `cmds:`, and no
  `patterns:` — a truly unbounded process spawn.
- **Dangling external grants.** An agent holding `fs.*` or `proc.*`
  with no hoistable sandbox (no grant `in:`, no agent `sandbox:`, no
  config `sandbox:`) has inert grants: every tool call denies with a
  scope violation. Doctor flags this with the fix: *"add `sandbox:`
  to the agent record, or set `sandbox:` in `~/.config/egghead/config.yml`
  for a machine-wide root."*
- **Sandbox backend availability.** On macOS, verifies
  `/usr/bin/sandbox-exec` is on PATH. On Linux, verifies `bwrap` is
  installed and prints the per-distro install command if missing
  (`apt install bubblewrap`, `dnf install bubblewrap`, etc.). On
  unsupported platforms, warns that `proc.*` tools will run
  unsandboxed.

Doctor warns; it does not block. Records always load. But the warnings
point at exactly the thing a typo or missing dependency in frontmatter
would corrupt silently.

## What happens when a grant doesn't cover a tool call

When an agent asks for something its capabilities don't cover, the
denial is visible in three places:

**To the LLM.** The tool result comes back with `is_error: true` and a
structured body naming the missing capability in plain English, so
the model can course-correct or escalate.

**To the transcript.** PubSub broadcasts an `{:agent_tool_denied, ...}`
event. The TUI and web chat render it as a distinct amber guardrail
entry — not a red crash, not a silent failure. You see exactly what
was asked for and what was missing.

**To the log.** `Logger.warning` with structured metadata (`agent_id`,
`tool`, `resource`, `verb`, `scope`). Useful for audit trails if you
keep your records directory under version control.

Five denial codes cover the taxonomy:

| Code                         | Meaning                                                |
|------------------------------|--------------------------------------------------------|
| `:capability_absent`         | No grant for the requested `resource.verb`             |
| `:scope_violation`           | Grant exists but the request falls outside scope       |
| `:self_modification`         | `agent.grant` with target == caller                    |
| `:exceeds_grantor_authority` | `agent.grant` proposing capabilities not ⊆ granter's   |
| `:unknown_tool`              | Tool name not registered                               |

## Skills — capabilities you don't have to write yourself

A **skill** is a `SKILL.md` record that describes a capability — an
instruction set plus the tools it leans on. Skills live either in the
record store (`class: skill`) or in a drop-zone directory (by default
`~/.agents/skills/`). Both sources are treated as first-class.

Skills never widen capabilities. `Egghead.Skill.inspect/1` parses a
`SKILL.md`, extracts the tools it references, and derives the
capability requirements (`WebFetch → net.get/post`, `Bash(rg) →
proc.exec{cmds: [rg]}`, and so on). At dispatch time the agent's
existing grants are checked against those derived requirements. A
skill that references tools the agent doesn't have capabilities for
just doesn't run — the grant is the gate.

Sandbox hoisting applies to skills at check time: a skill's `Bash(...)`
translation maps to `proc.exec`, and the effective `in:` for that
grant resolves through the agent's sandbox chain like any other
capability. `egghead skills check <skill> --agent <id>` surfaces
sandbox violations alongside the usual capability delta.

Inspect before you curate:

```bash
egghead skill list
egghead skill inspect <id-or-path>
egghead skill check <id> --agent <agent-id>
```

## Provider tools and server-side scoping

Some tools live locally (`get_record`, `fs_read`, `web_fetch`); others
are provided by the LLM vendor and execute server-side (Anthropic's
`web_search`, `code_execution`). The capability check happens at a
different point for each:

- **Local tools.** Checked at dispatch time, with full parameter
  awareness. A call to `web_fetch` against `evil.example.com` is
  denied before the request leaves the node.
- **Provider tools with scoping.** The tool is only included in the
  request to the LLM at all if the agent holds the relevant grant;
  its scope is translated into the provider's native allow-list. An
  agent with `net.get{hosts: ["*.github.com"]}` gets a `web_search`
  tool configured with `allowed_domains: ["github.com"]`, enforced
  server-side.
- **Provider tools without scoping.** All-or-nothing. They require a
  coarse, explicit capability that is never granted by default.

One honest limitation: provider tool results land back in the model's
context in the same turn, so content passing through them can't be
scanned for prompt injection before it arrives. When a tool can be
implemented locally, that's the safer path.

## Inspirations

Egghead's capability model didn't invent anything. It stitches
together ergonomics and enforcement ideas from three lineages:

**OpenBSD pledge/unveil.** The *declaration style* and the
*split between verbs and filesystem view*. `pledge(2)` is a process's
list of allowed verbs; `unveil(2)` restricts which parts of the
filesystem those verbs can touch. Egghead's `capabilities:` is the
pledge — what an agent can do. Egghead's `sandbox:` / `in:` is the
unveil — where it can be done. The two halves compose the same way:
both lists can only narrow, never widen, and both are enforced by the
kernel once declared. 33 of OpenBSD's 36 boot processes use `pledge`;
3 of 47 use Capsicum. Simplicity drove adoption, and egghead follows
the same posture: one declaration per record, widening is a human
edit, never a runtime "allow once" prompt. We take the enforcement
from `sandbox-exec` (macOS) and `bwrap` (Linux) rather than pledge
itself because egghead runs on developer laptops where those are the
native primitives; OpenBSD pledge would be a future-work natural fit.
Man pages: [pledge(2)](https://man.openbsd.org/pledge.2),
[unveil(2)](https://man.openbsd.org/unveil.2).

**FreeBSD Capsicum.** The *granularity*: rights attach to scoped
resources, not just verbs. Capsicum capabilities can be restricted
further but never expanded, and restrictions are irreversible. This
is the shape of Egghead's scope vocabulary — `net.get{hosts}`,
`fs.read{in, paths}`, `proc.exec{in, cmds, patterns}`. A grant
narrows the verb to specific parameters; there is no syntax to
expand at runtime.
Original paper: [Watson et al., *Capsicum: Practical Capabilities for
UNIX*,
USENIX Security 2010](https://www.usenix.org/conference/usenixsecurity10/capsicum-practical-capabilities-unix).

**Google Macaroons.** The *delegation model*: authorization tokens
with chained caveats, where a holder can add restrictions without
contacting the issuer. Subset-only delegation, provable without
coordination. This is where Egghead's `agent.grant` attenuation
check comes from: when one agent grants capabilities to another,
the proposed grants must be ⊆ the granter's own, including scope.
No agent can hand out authority it doesn't hold.
Original paper: [Birgisson et al., *Macaroons: Cookies with Contextual
Caveats for Decentralized Authorization in the Cloud*,
NDSS 2014](https://research.google/pubs/pub41892/).

## What the capability model doesn't solve

Worth naming explicitly, so you know what you're trusting:

- **Content laundering through provider tools.** Web search results
  re-enter the model's context in the same turn. We can't scan them
  before they land.
- **Sibling collusion.** An agent with `agent.grant` can spawn peers
  with identical authority. Each operates within its scope (no
  widening), but coordination across processes isn't controlled. This
  is fundamental to capability systems, not specific to Egghead.
- **Cross-node delegation.** The attenuation check runs in-process.
  If a capability ever needs to cross a network or process boundary
  intact, a serialized-token scheme (along macaroon lines) is what
  would make that sound. Not needed yet.
- **FS tools run in-BEAM.** `fs.read` and `fs.write` are implemented
  in Elixir inside the BEAM, so the sandbox fence is advisory for
  them (path-prefix checked by the matcher against the hoisted root).
  `proc.*` is kernel-fenced; everything an allowed command does is
  contained. A future pass could route FS ops through a per-session
  sandboxed helper process, closing this gap, but the attack surface
  today is small — only our own audited code runs there, not
  arbitrary third-party binaries.
- **Unsupported platforms.** The kernel sandbox works on macOS
  (`sandbox-exec`) and Linux (`bwrap`). Windows, the BSDs, and
  illumos fall through to unsandboxed `Port.open` with a startup
  warning. `proc.*` grants work there, but without the kernel fence;
  the Elixir matcher's advisory checks are the only line. OpenBSD
  has native `pledge`/`unveil` that'd be a natural fit and is a
  candidate for a later pass.
- **`sandbox-exec` is Apple-deprecated.** It still ships on every
  macOS (including Sequoia) and is used heavily by Apple's own
  internals, but Apple has marked both it and `sandbox_init_with_parameters`
  deprecated without documenting a supported replacement. If Apple
  ever actually removes it, this pass will need a follow-up — likely
  routing through Endpoint Security Framework or a different
  approach entirely.
- **Linux network hostname scoping is coarse.** `bwrap`'s
  `--unshare-net` is all-or-nothing per subprocess. macOS
  `sandbox-exec` supports hostname-scoped network rules; Linux
  doesn't without a separate proxy layer. Today we expose all-or-nothing
  on Linux and defer hostname scoping to a later pass.

These are honest limits of the current implementation. The one
limitation the earlier version of this guide named — *"a compromised
tool can exfiltrate data if the tool code itself is hostile"* — is no
longer in the list. The kernel sandbox closes that gap: a hostile
binary under a `proc.exec` grant hits EPERM trying to read outside
the fence, regardless of what the argv allowlist did or didn't check.
