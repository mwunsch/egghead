---
title: Capabilities
section: Capabilities
weight: 21
summary: Per-agent grants of resource.verb pairs, optionally scoped, enforced at the call site and (for filesystem and process verbs) by an OS sandbox.
---

Egghead is a [capability-based security
system](https://en.wikipedia.org/wiki/Capability-based_security).
A capability is a `resource.verb` string, optionally with a
scope, that names exactly one thing an agent is allowed to do.
Each agent record declares the capabilities its process holds in
the frontmatter, and Egghead checks every tool call against that
list. Filesystem and subprocess verbs are additionally enforced
by an operating-system sandbox —
[`sandbox-exec`](https://manp.gs/mac/1/sandbox-exec) on
macOS,
[`bwrap`](https://github.com/containers/bubblewrap) (bubblewrap)
on Linux — so a compromised binary running under a permitted
`proc.exec` cannot escape the fence even if it tries.

The shape is most directly inspired by OpenBSD's
[`pledge(2)`](https://man.openbsd.org/pledge.2) and
[`unveil(2)`](https://man.openbsd.org/unveil.2). `pledge` is a
list of allowed verbs a process declares about itself; `unveil`
is the list of paths those verbs are allowed to touch. Egghead's
`capabilities:` field plays the role of `pledge` (what the agent
can do) and the `sandbox:` and `in:` fields play the role of
`unveil` (where the agent can do it). The same rule applies to
both halves: each list can only narrow over the agent's
lifetime, never widen, and any expansion is an explicit edit to
the agent's record. The fuller bibliography for this lineage —
Capsicum, Macaroons — is in
[Research influences]({{< ref "research-influences" >}}).

Most agent harnesses you have probably used take a different
approach to authority. They show you a runtime prompt — *Allow
once*, *Allow always*, or the popular escape hatch
`--dangerously-skip-permissions` — and they ask you to make a
decision in the middle of the agent's turn. That works for
single-agent systems where you are watching the output as it
happens. It scales poorly to a roster of agents acting in
parallel, and it puts the security decision exactly where you
have the least time to think about it. Egghead does the
opposite: capabilities are written into the agent's record
*ahead of time*, where you can read them, diff them, audit them
in Git, and revoke them between sessions. There is no runtime
prompt at the tool-call site. Widening an agent's authority is
an edit to a Markdown file.

The catalog of tools each capability unlocks — built-in record
operations, network, filesystem, subprocess, plus anything you
register from an MCP server — is documented separately in
[Tools]({{< ref "tools" >}}). This guide is the authority side;
that one is the menu side.

## Resource families and verbs

| Resource  | Verbs                                          |
|-----------|------------------------------------------------|
| `records` | `read`, `create`, `update`, `delete`           |
| `agent`   | `create`, `update`, `delete`, `grant`          |
| `fs`      | `read`, `write`, `delete`                      |
| `net`     | `get`, `post`, `put`, `delete`                 |
| `proc`    | `exec` (argv-style), `eval` (shell pipelines)  |

The `records` and `agent` resources are split deliberately. A
call that targets an agent record always requires an
`agent.*` grant, regardless of any `records.*` scope. An agent
holding only `records.update` cannot edit another agent's
frontmatter — by design.

## Risk tiers

Every capability in the catalog carries a risk level. The CLI,
the agent wizard, and `egghead doctor` sort and color their
output by risk so you see the consequential grants first.

| Risk    | Capabilities                                                         |
|---------|----------------------------------------------------------------------|
| Low     | `records.read`, `records.create`                                     |
| Medium  | `records.update`, `fs.read`, `net.get`, `agent.update`               |
| High    | `records.delete`, `fs.write`, `fs.delete`, `net.post`/`put`/`delete`, `proc.exec`, `proc.eval`, `agent.delete`, `agent.grant` |

Low-risk capabilities are reasonable defaults for most agents.
Medium- and high-risk capabilities should be scoped narrowly to
the smallest surface that lets the agent do its job.

## Grant syntax

```yaml
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

The bare form (no scope) means different things by family.
Internal verbs — `records.*` and `agent.*` — default to the
universe in the bare form, so `records.read` on its own means
"read any record." External verbs — `net.*`, `fs.*`,
`proc.*` — default to *empty* in the bare form, so `net.get` on
its own grants nothing until you scope it. The explicit
"any host" form is `net.get: { hosts: ["*"] }`.

This rule exists so that a typo or an omitted scope cannot
silently grant unrestricted external access. Wide grants are
allowed; they just have to be written down.

## Scope keys

| Verb               | Scope keys                          |
|--------------------|-------------------------------------|
| `records.create`   | `classes` (string list)             |
| `records.update`   | `classes`, `paths`                  |
| `records.delete`   | `classes`                           |
| `agent.create`     | `id`                                |
| `agent.update`     | `id`, `ids`, `paths`                |
| `agent.delete`     | `id`, `ids`                         |
| `agent.grant`      | `id`                                |
| `fs.read`          | `in`, `paths`                       |
| `fs.write`         | `in`, `paths`                       |
| `fs.delete`        | `in`, `paths`                       |
| `net.get`/`post`/`put`/`delete` | `hosts`                |
| `proc.exec`        | `in`, `cmds`, `patterns`            |
| `proc.eval`        | `in`                                |

Entries in `paths:` resolve relative to `in:`. Any `..` segment
that would escape `in:`, or any absolute path outside `in:`, is
rejected at parse time rather than silently trimmed at runtime.
Scopes are allow-lists only; there is no "everything except"
syntax. Multiple grants of the same verb union additively.

## The sandbox

`fs.*` and `proc.*` grants are scoped to a sandbox root, the
`in:` key. Egghead's capability matcher rejects any call whose
target path is outside that root. For `proc.*`, the actual
subprocess additionally executes inside an OS-level sandbox
(`sandbox-exec` on macOS, `bwrap` on Linux), which means the
kernel itself prevents the subprocess from reaching anything
outside the root, even if the program tried. For `fs.*`, the
in-process matcher is currently the only line of defense; see
the [Known limitations](#known-limitations) section for what
that implies in practice.

The sandbox root is resolved through a hoist chain:

1. Per-grant: the grant's own `in:` value.
2. Per-agent: a top-level `sandbox:` key in the agent record's
   frontmatter.
3. Config-level: a top-level `sandbox:` key in
   `~/.config/egghead/config.yml`.

Deeper levels narrow the root; missing levels inherit. If an
agent declares `sandbox: /etc` under a config that says
`sandbox: ~/Work`, the agent is clamped to `~/Work` at load
time with a warning. Sandboxes only narrow.

If an `fs.*` or `proc.*` grant has no hoistable `in:` at any
of the three levels, the grant stays inert — every tool call
denies. `egghead doctor` flags this with a fix.

`net.*` uses `hosts:` instead of `in:`, so it is not affected
by the hoist chain.

### `sandbox:` as agent shorthand

```yaml
---
id: agents/scout
class: agent
sandbox: ~/projects/foo
capabilities: [records.read]
---
```

That record expands at load time to:

```yaml
capabilities:
  - records.read
  - fs.read:   { in: ~/projects/foo }
  - fs.write:  { in: ~/projects/foo }
  - proc.exec: { in: ~/projects/foo }
```

`proc.eval` and `net.*` are deliberately not in the shorthand;
both have to be declared explicitly because their risk profile
is higher than the three the shorthand covers.

### Backend availability

`egghead doctor` verifies that the sandbox backend is present
on your platform. On macOS it checks for `/usr/bin/sandbox-exec`,
which ships with the OS. On Linux it checks for `bwrap` and
prints the per-distro install command if it is missing. On
other platforms — Windows, the BSDs — `proc.*` runs without a
sandbox, with a warning at startup.

## Defaults and the `access:` shorthand

An agent record with no `capabilities:` and no `access:` loads
with `[records.read]` as its only grant. To declare an
explicitly authority-free agent, write `capabilities: []` —
useful occasionally (a persona whose only job is to react in
prose), but it's the deliberate case rather than the default.

For the common record-family bundles, `access:` is a
chmod-flavored shorthand:

| `access:` | Expands to                                          |
|-----------|-----------------------------------------------------|
| `r`       | `records.read`                                      |
| `w`       | `records.create`, `records.update`                  |
| `rw`      | `records.read`, `records.create`, `records.update`  |

Deletion is deliberately excluded; the catalog flags
`records.delete` as high risk, and the shorthand never bundles
risky verbs.

`access:` unions with `capabilities:` (deduped at load time).
Write both, and the merged set is what the agent runs with.
The first time an agent is widened by `egghead agents grant`,
the shorthand is dissolved into explicit `capabilities:`
entries on disk so the frontmatter always reflects the agent's
real authority.

## Attenuation

`agent.grant` lets an agent write the `capabilities:` (or
`access:`, `sandbox:`) field of another agent's record. Two
rules keep this from turning into a capability escape.

First: an agent cannot use `agent.grant` to widen itself.
Self-modification is denied, regardless of which grants the
agent holds.

Second: a granter can only pass on capabilities that are a
subset of its own, including scope. If the granter holds
`net.get{hosts: ["*.github.com"]}`, it can grant
`net.get{hosts: ["github.com"]}` to another agent, but it
cannot grant `net.get{hosts: ["*"]}` — that would exceed the
granter's authority.

Violations surface in three places: the tool result the
granting agent sees (so the model can course-correct), the
room transcript (rendered as a guardrail event), and the log.

## CLI

```bash
egghead agents capabilities <agent-id>     # held grants, sorted by risk
egghead agents grant <agent-id> <spec>     # widen, with confirmation
egghead agents revoke <agent-id> <spec>    # narrow
```

The spec grammar matches the YAML shape in compact form:

```bash
egghead agents grant scout 'net.get{hosts=[*.github.com,api.anthropic.com]}'
egghead agents grant scout 'proc.exec{in=~/Work,cmds=[rg,jq]}'
egghead agents revoke scout records.update
```

`egghead agents grant <agent-id>` with no spec opens an
interactive picker over the catalog, sorted from low risk to
high.

When you `grant` or `revoke` against an agent that uses
`access:` or `sandbox:`, the CLI dissolves the shorthand into
explicit `capabilities:` entries and rewrites the record. This
is a deliberate contract: the frontmatter on disk always
reflects the agent's effective authority, with no ambiguity
between a shorthand and an out-of-sync explicit list.

## What `egghead doctor` checks

For each `class: agent` record, `egghead doctor` runs the
following validations.

It flags unknown capability names and suggests close matches
for likely typos. It flags unknown scope keys, such as `pathz`
where `paths` was meant. It flags scope values whose types do
not match what the key expects. It flags escalation risks,
such as an `fs.write` grant whose `paths` scope covers your
records directory or a `proc.exec` grant with no `in:`,
`cmds:`, or `patterns:`. It flags external grants that have
no hoistable sandbox root and would therefore be inert. And
it checks that the sandbox backend is available for the
current platform.

`doctor` warns; it does not block. Records always load even
when warnings fire, but the warnings name the exact thing a
typo or missing dependency in frontmatter would corrupt
silently otherwise.

## Denial codes

When a tool call falls outside an agent's grants, the runtime
emits one of these codes:

| Code                         | Meaning |
|------------------------------|---------|
| `:capability_absent`         | No grant for the requested `resource.verb`. |
| `:scope_violation`           | A grant exists, but the request is outside its scope. |
| `:self_modification`         | `agent.grant` was called with the granting agent as its own target. |
| `:exceeds_grantor_authority` | `agent.grant` proposed capabilities that are not a subset of the granter's. |
| `:unknown_tool`              | The tool name is not registered. |

The denial is delivered to the model as a tool result with
`is_error: true` and a structured body, to the room transcript
as a guardrail event, and to `Logger.warning` with the
relevant metadata. The agent's next turn can read its own
denial and adjust.

## Skills and capabilities

A skill declares the tools it depends on in its `allowed-tools`
field. At discovery time, Egghead checks the asking agent's
capabilities against the skill's derived requirements; skills
the agent cannot satisfy are filtered out silently. A skill
that requires `WebFetch(domain:github.com)` will only appear
to agents that hold `net.get{hosts: ["github.com"]}` or
broader.

Skills never widen capabilities. The full skill format and
the CLI for inspecting skill-vs-agent gaps are documented in
[Skills]({{< ref "skills" >}}).

## Provider tools

Some tools execute on the LLM provider's side rather than
locally — Anthropic's `web_search`, OpenAI's `code_execution`,
and so on. Capability checks for those run at
request-construction time. The tool is omitted from the
request entirely if the agent does not hold the matching
grant. Where the provider supports allow-listing, the agent's
scope is translated to the provider's native form (a
`net.get{hosts: ["github.com"]}` grant becomes a
`web_search` request configured with
`allowed_domains: ["github.com"]`, enforced server-side).
Provider tools that do not support scoping require an
explicit, never-default capability.

One honest limitation: provider tool results land back in the
model's context the same turn they are called, so the content
they return cannot be scanned for prompt injection before it
arrives. When a tool can be implemented locally, the local
path is safer.

## Known limitations

A few honest gaps in the current implementation, worth knowing
about.

`fs.*` has one layer of enforcement; `proc.*` has two. Both
go through the in-process capability matcher, which rejects
any call whose target falls outside the agent's sandbox root
before the operation runs — so a path-traversal attempt or a
typo'd absolute path is denied at the matcher and never
reaches the file system. The difference is what happens *if*
the matcher ever lets something through: `proc.exec` and
`proc.eval` execute their subprocess under the OS sandbox, so
the kernel still contains the process; `fs.*` operations run
inside the Egghead BEAM with the BEAM's own credentials, with
no second line of defense. A future release could route
filesystem operations through a sandboxed helper process to
close that gap.

Linux network scoping is coarser than macOS's. `bwrap`'s
`--unshare-net` is all-or-nothing per subprocess; macOS
`sandbox-exec` supports hostname-scoped network rules. Cross-
platform hostname scoping for processes would require a proxy
layer.

`sandbox-exec` on macOS is officially deprecated by Apple.
It still ships on every macOS version through Sequoia, but
Apple has not documented a supported replacement. If Apple
ever removes it, the macOS backend will need to be rebuilt
against a different primitive.

Sibling collusion is not prevented. An agent holding
`agent.grant` can spawn peer agents with the same authority.
Each peer operates within scope (no widening), but
coordination between them is not constrained. This is
inherent to capability systems generally, not specific to
Egghead.
