---
title: Records
weight: 10
---

A record is the atomic unit of the Egghead store — a plain Markdown
file (or org-mode file) with optional frontmatter, sitting in a
directory on your filesystem. Every knowledge artifact the system
touches — notes, agent definitions, skills, saved transcripts,
deliberation audit trails — is a record in the same shape.

This guide covers what's in a record, how the parser reads one, and
what the graph layer does with it.

## A record on disk

The minimum viable record is one line of Markdown in a file:

```markdown
This is a record. No frontmatter needed.
```

Drop it in your records directory (default `~/.egghead/`), and the
file watcher will index it. The id is derived from the file path;
the title, from the first heading; everything else stays empty.

The fully-decorated form adds YAML frontmatter at the top:

```markdown
---
id: notes/postgres-vacuum
title: Postgres autovacuum, in one page
tags: [postgres, operations, reference]
links: [notes/postgres-mvcc]
class: durable
---

# Postgres autovacuum

Background worker that removes dead tuples from tables, making space
reusable. See [[notes/postgres-mvcc]] for why dead tuples exist in
the first place.
```

The fence is three dashes, alone on a line, at both ends of the YAML
block. org-mode files use a `:PROPERTIES:` ... `:END:` drawer with the
same semantics — pick whichever format you prefer; both live in the
same store.

## Frontmatter keys

Seven keys have structural meaning. Everything else in the frontmatter
is preserved verbatim as arbitrary metadata.

| Key       | Type            | Purpose                                     |
|-----------|-----------------|---------------------------------------------|
| `id`      | string          | Globally unique identifier                  |
| `title`   | string          | Display name; falls back to first heading   |
| `tags`    | list of strings | Free-form labels for filtering and search   |
| `links`   | list of strings | Authored references to other record ids     |
| `class`   | enum            | `durable`, `inbox`, `deliberation`, `transcript`, `agent`, `skill` |
| `created` | ISO 8601 string | Authored creation time (optional)           |
| `author`  | string          | Author name; falls back to file owner       |

Omit any of them and the parser fills in sensible defaults or leaves
the field empty. The only truly required field is a usable `id`, and
even that is derived from the filename if absent.

## ID derivation

If you don't write an `id:` line yourself, the parser takes the file
path relative to your records directory and strips the extension.

- `~/.egghead/projects/rewrite-auth.md` → `projects/rewrite-auth`
- `~/.egghead/inbox.md` → `inbox`
- `~/.egghead/skills/pr-review/SKILL.md` → `skills/pr-review/SKILL`

If you do write an `id:` line, that wins. Move the file to a new
directory and the id doesn't change — the record's identity is in
the frontmatter, not the path.

Ids are strings, not URLs. Slashes are for organization and read
cleanly in `[[wikilinks]]`. Nothing enforces a naming scheme.

## Timestamps: `updated` is the filesystem's

Two timestamp fields exist and they behave differently:

- **`updated`** — always derived from the file's modification time.
  Never authored, never written back to frontmatter. If you paste an
  `updated:` line into a record, it's stripped on the next write.
- **`created`** — authorable with filesystem fallback. If you write
  `created: 2024-11-03` in the frontmatter, that value sticks. If you
  don't, the filesystem's birthtime (macOS) or ctime (Linux) fills it
  in at read time, but the derived value is not written back — so a
  record you never meant to give a creation date stays ungarnished in
  the yaml.

The point: your editor's save time is always authoritative for
"when was this touched," and you never have to chase a stale
`updated:` line you forgot to bump.

## Links and wikilinks

Egghead has two ways to point at another record, and the distinction
matters.

**Authored links** live in frontmatter:

```yaml
links: [notes/postgres-mvcc, references/pg-docs-autovacuum]
```

These are stable, deliberate references. They show up in the
backlink index, in `egghead_find_links`, and anywhere the graph is
queried.

**Wikilinks** live in the body:

```markdown
See [[notes/postgres-mvcc]] for background, or
[[notes/postgres-vacuum#tuning|the tuning section]] for the practical
bits.
```

These are demonstrative — prose references that happen in-situ. The
parser extracts them into a separate `wikilinks` field on the record,
complete with fragment and display text. They *also* feed the backlink
index (so traversal sees both), but they never leak back into the
authored `links:` list. If you paste `[[notes/postgres-mvcc]]` in a
sentence, it doesn't quietly become a permanent metadata attachment.

Wikilink syntax:

- `[[target]]` — plain reference
- `[[target|custom display text]]` — render `custom display text`
- `[[target#section]]` — fragment
- `[[target#section|display]]` — both

The graph layer exposes either view: `Egghead.find_links/2` returns
authored forward references; `Egghead.find_backlinks/1` returns the
union of authored and body-derived inbound references.

## Tags

Tags are flat strings. They filter search results, gate agent
activation (an agent's tags are matched against incoming messages
during relevance scoring — see the [Chat rooms
guide]({{< ref "chat-rooms" >}})), and group related records visually
in the TUI.

Two conventions worth knowing:

- Use **lowercase** and **hyphens** (`operations`, `post-incident`,
  `half-baked`). The parser doesn't care, but search behaves more
  predictably when you're consistent.
- Use tags for kinds of thing, not for topics of thing. A tag like
  `research` says "this is ongoing investigation"; a tag like
  `postgres` says "this is about Postgres." Both are fine; mixing
  them in the same record is fine too. There's no taxonomy.

## Class

One key deserves its own section because it changes how a record is
treated by the rest of the system. Six classes exist — `durable`,
`inbox`, `deliberation`, `transcript`, `agent`, `skill`. See the
[Record classes guide]({{< ref "record-classes" >}}) for when to
reach for each.

If you don't write a `class:` line, the default is `durable` — a
permanent note in the store. That's the right choice most of the
time.

## Body

Everything after the frontmatter is the record's body. The parser
understands:

- **GitHub-flavored Markdown** — headings, lists, tables, fenced code
  blocks, task lists (`- [ ]` / `- [x]`), strikethrough.
- **org-mode** — headings, lists, property drawers, links, source
  blocks, as rendered by the built-in org parser.
- **Wikilinks** — as above, on both sides of the format divide.

The AST is cached on the record so downstream consumers (TUI preview,
web renderer, search snippetting) don't re-parse. Files that exceed
the "too big to parse" threshold fall back to a plain-text view; the
search index still covers them.

## Search and traversal

The SQLite index (derived, rebuildable, at
`<records_dir>/.egghead/index.db`) provides three things:

- **Full-text search** via FTS5 with porter stemming — fast, cheap,
  ranked. `Egghead.search/2` or the `egghead_search` MCP tool.
- **Link traversal** — forward references from a record, reverse
  references into it. `Egghead.find_links/2` and
  `Egghead.find_backlinks/1`.
- **Recency** — records sorted by updated time.
  `Egghead.recent/1`.

Nothing in the index is authoritative — delete `index.db` and the
store rebuilds it from the file tree at startup. The source of truth
is always the Markdown on disk.

## Creating and updating

Three paths:

1. **Your editor.** Drop a file in the records directory, the file
   watcher picks it up, the index updates. On Linux this needs
   `inotify-tools` installed — `egghead doctor` flags that if it's
   missing. macOS uses FSEvents natively.
2. **The TUI.** Type a title that doesn't match any existing record
   and hit Enter — Egghead scaffolds a new file and opens it in
   `$EDITOR`.
3. **The API or MCP tool.** `Egghead.create_record/1`,
   `Egghead.update_record/2`, or their MCP equivalents
   (`egghead_create`, `egghead_update`). These go through the same
   parser and write barrier as editor edits, so no matter how a
   record lands, it lands the same way.

Agents with the appropriate capabilities (see the
[Capabilities guide]({{< ref "capabilities" >}})) can create and
update records through tools. Whether to grant that is a deliberate
choice — reads are safe, writes deserve a thought.

## A record is a file

The design closes the loop: the file on disk is the record. There is
no separate "database of records" that the files synchronize to. The
index is a cache; the [agents]({{< ref "agents" >}}) are processes;
the [chat rooms]({{< ref "chat-rooms" >}}) are conversations.
Everything else can be rebuilt from the directory.

That's the practical consequence: `cp -r ~/.egghead/ /backup/`
preserves your store. `git init ~/.egghead/` gives you version
control. `grep -r "postgres" ~/.egghead/` answers questions when the
server is down. Whatever tooling you already have for Markdown on a
filesystem — ripgrep, fzf, your favorite editor — works here
unchanged.
