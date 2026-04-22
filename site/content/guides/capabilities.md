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

This guide is for anyone running an Egghead node. It covers what to
write in an agent's frontmatter, how grants compose, what the CLI and
`egghead doctor` will catch, and how agents delegate authority to each
other.

## The shape of a grant

Every capability is a `resource.verb` pair, optionally with a scope.

```yaml
capabilities:
  - records.read
  - records.update:
      classes: [deliberation, inbox]
  - net.get:
      hosts: ["*.github.com", "api.anthropic.com"]
  - shell.exec:
      cmds: [rg, jq, git]
```

Five resource families cover the whole surface:

| Resource  | What it governs                              |
|-----------|----------------------------------------------|
| `records` | Content records — read, create, update, delete |
| `agent`   | Agent records specifically — create, update, delete, **grant** |
| `fs`      | Files *outside* the record store             |
| `net`     | Outbound HTTP — `get`, `post`, `put`, `delete` |
| `shell`   | Running local commands                       |

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
| **High**   | `records.delete`, `fs.write`, `fs.delete`, `net.post`/`put`/`delete`, `shell.exec`, `agent.delete`, `agent.grant` |

Low-risk capabilities are the ergonomic default. Medium- and high-risk
capabilities should be scoped.

## Bare vs scoped — know the difference

The bare form (`- net.get` on its own line) and the scoped form
(`- net.get: { hosts: [...] }`) mean different things depending on the
resource family.

**Internal resources** (`records.*`, `agent.*`) default bare-to-universe:

```yaml
- records.read        # read any record — fine
- records.update      # update any record — probably too wide
```

**External resources** (`net.*`, `fs.*`, `shell.exec`) default
bare-to-empty — a bare grant is inert until scoped:

```yaml
- net.get             # inert: no hosts, no fetches allowed
- net.get:            # useful: explicitly allow any host
    hosts: ["*"]
```

The `"*"` entry is a valid, auditable declaration of "any". It is
different from the bare form and different from omitting the grant
entirely. The rule is there so no agent silently ends up with
unrestricted net or filesystem access.

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
egghead agents grant scout 'shell.exec{cmds=[rg,jq]}'
egghead agents revoke scout records.update
```

`egghead agents grant <agent-id>` with no spec opens an interactive
picker over the catalog, sorted low-risk first.

### Grant, revoke, and the `access:` shortcut

When you `grant` or `revoke` on an agent declared with `access:`, the
CLI dissolves the shortcut: the record is rewritten with an explicit
`capabilities:` list covering the unified set (access-expanded plus
whatever was already there, plus or minus your change) and the
`access:` key is removed. The contract is that the frontmatter on
disk always reflects the agent's real authority — you never see
`access: rw` sitting next to an out-of-sync `capabilities:` list.

Shortcut-only agents that you don't touch with tooling keep their
shorthand indefinitely. The dissolution fires only when you mutate.

The same dissolution applies when agents grant each other via
`create_record` / `update_record` — a write that touches
`capabilities:` or `access:` on an agent record always lands as
explicit `capabilities:` with no `access:` key. This also closes the
escalation hole where an agent with `agent.update` (but not
`agent.grant`) might otherwise write `access: rw` to widen another
agent silently.

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
  model can be bypassed by writing records directly. Same goes for
  `shell.exec` granted with no `cmds` and no `patterns`: a bare shell
  grant can edit any file.

Doctor warns; it does not block. Records always load. But the warnings
point at exactly the thing a typo in frontmatter would corrupt
silently.

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
shell.exec{cmds: [rg]}`, and so on). At dispatch time the agent's
existing grants are checked against those derived requirements. A
skill that references tools the agent doesn't have capabilities for
just doesn't run — the grant is the gate.

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

**OpenBSD pledge/unveil.** The *declaration style*: list what a
process is allowed to do in one place, and only ever narrow from
there. 33 of OpenBSD's 36 boot processes use `pledge`; 3 of 47 use
Capsicum. Simplicity drove adoption. Egghead inherits this: you
declare grants in one place (the agent record's frontmatter), and
widening is a human edit, never a runtime "allow once" prompt.
Man pages: [pledge(2)](https://man.openbsd.org/pledge.2),
[unveil(2)](https://man.openbsd.org/unveil.2).

**FreeBSD Capsicum.** The *granularity*: rights attach to scoped
resources, not just verbs. Capsicum capabilities can be restricted
further but never expanded, and restrictions are irreversible. This
is the shape of Egghead's `scope:` — `net.get{hosts}`,
`fs.write{paths}`, `shell.exec{cmds}`. A grant narrows the verb to
specific parameters; there is no syntax to expand at runtime.
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

- **Compromised tool implementations.** A malicious `shell.exec` with
  a whitelisted `rg` can still exfiltrate data if the tool code itself
  is hostile. BEAM/OTP isolates faults, not attackers. Containerized
  or microVM-per-tool isolation is future work.
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

These are honest limits of the model in its current form. The
enforcement surface is real; the trust boundary it establishes is
between the *model* and the tools it asks for, not between a
compromised tool and the machine it runs on.
