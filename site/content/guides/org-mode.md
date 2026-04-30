---
title: Org-mode
section: Integrations
weight: 34
summary: Egghead reads and writes org-mode files alongside Markdown ones.
---

A record can be a Markdown file or an [org-mode](https://orgmode.org/)
file. Both live in the same store, share the same id and link
graph, and parse into the same shape. The choice is per-file;
`.md` and `.org` records sit in the same directory and link to
each other.

Org support exists so an Emacs user with an existing
[org-roam](https://www.orgroam.com/),
[Denote](https://protesilaos.com/emacs/denote), or
[Logseq](https://logseq.com/) directory can run Egghead against
their notes without converting anything.

## Setup

Point `records_dir` at the directory and, if you want records
created by Egghead itself to be `.org` rather than `.md`, set
`default_format`:

```yaml
records_dir: ~/org/roam
default_format: org
```

`default_format` only chooses the extension and writer for new
records. Existing files keep their on-disk format. The full
configuration schema is documented in
[Configuration]({{< ref "configuration" >}}).

## Frontmatter mapping

Org has no separate frontmatter section; `#+`-keywords and the
file-level `:PROPERTIES:` drawer are part of the document.
Egghead reads them in place.

| Org syntax                            | Record field |
|---------------------------------------|--------------|
| `#+TITLE:`                            | `title`      |
| `#+AUTHOR:`                           | `author`     |
| `#+TAGS:` or `#+FILETAGS:`            | `tags`       |
| `:ID:` (file-level drawer)            | `id`         |
| `:LINKS:`                             | `links`      |
| `:CLASS:`                             | `class`      |
| `[[target]]` / `[[target][display]]`  | wikilink     |
| `* Headlines`                         | outline      |

The drawer must come before the first headline to count as
file-level; drawers attached to subtrees stay headline-local.
Anything Egghead doesn't recognize — `#+OPTIONS:`, `#+STARTUP:`,
custom drawer keys, `LOGBOOK`, `CLOCK` lines — is preserved on
disk and ignored at the record level.

The fields themselves carry the same meaning as in
[Records]({{< ref "records" >}}); only the surface syntax
differs.

## Agents in org-mode

A `class: agent` org file is an agent. The disposition is the
prose body. On load, Egghead strips the leading `#+`-keyword
block and the file-level `:PROPERTIES:` drawer from the body
before passing it to the model — the file on disk is unchanged,
the model just doesn't see the metadata twice.

```org
#+TITLE: Archivist
#+FILETAGS: :agent:
:PROPERTIES:
:ID: agents/archivist
:CLASS: agent
:MODEL: anthropic/claude-sonnet-4-6
:SANDBOX: ~/Work
:CAPABILITIES: records.read records.create net.get{hosts=[orgmode.org,gnu.org]}
:END:

You are the archivist. ...
```

`:CAPABILITIES:` is a single string of grants in the same compact
form `egghead agents grant` accepts. The grant grammar, scope
keys, and `sandbox:` shorthand work exactly as documented in
[Capabilities]({{< ref "capabilities" >}}); this is the
string-valued surface of the same thing.

## What Egghead doesn't do

Subtree property drawers are read and preserved on disk but are
not extracted into record metadata. Only the file-level drawer
promotes to record fields.

Babel evaluation is not implemented. Source blocks are indexed
and rendered; nothing executes.

Agenda and clock entries (`CLOCK:`, `:LOGBOOK:`) survive on disk
but Egghead does not treat them as structured data.

`#+INCLUDE:` transclusion is preserved verbatim, not resolved.

## See also

- [Records]({{< ref "records" >}}) covers the record model.
- [Agents]({{< ref "agents" >}}) covers the rest of an agent
  record's frontmatter.
- [Capabilities]({{< ref "capabilities" >}}) covers the grant
  grammar referenced above.
- [Worg](https://orgmode.org/worg/) and the
  [org-roam discourse](https://org-roam.discourse.group/) for
  background on the conventions Egghead inherits.
