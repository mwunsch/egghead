---
title: Records
section: Records
weight: 10
summary: A record is a Markdown file in a directory you choose. Optional YAML frontmatter, wikilinks for graph structure, FTS5 for search.
---

A record is a Markdown file in your records directory. The default
records directory is `~/.egghead`; you can change it by editing
`records_dir` in `config.yml`. Every other thing Egghead knows
about — agents, skills, saved chat transcripts, deliberation
summaries — is also a record, distinguished by its `class:`
frontmatter value. The full list of classes lives in
[Record classes]({{< ref "record-classes" >}}).

Records can also be org-mode files (`.org`); see
[Org-mode]({{< ref "org-mode" >}}) if that's your workflow.

Most multi-agent frameworks store their state in an internal
database. Egghead does not. Your store is a folder you can open
in Obsidian, edit in `vim`, sync with iCloud, commit to Git, or
back up by copying the directory. Egghead reads and writes those
files; it does not own them.

## File format

The smallest possible record is one line of Markdown:

```markdown
This is a record.
```

Egghead derives the record's id from its path relative to the
records directory, with the extension stripped. The title comes
from the first heading; if there is no heading, the title falls
back to the id. Everything else is empty.

A fully-decorated record adds YAML frontmatter at the top:

```markdown
---
id: notes/postgres-vacuum
title: Postgres autovacuum, in one page
tags: [postgres, operations]
links: [notes/postgres-mvcc]
class: durable
---

# Postgres autovacuum

Background worker that removes dead tuples from tables. See
[[notes/postgres-mvcc]] for context.
```

The YAML block is fenced by three dashes alone on a line, both
at the top and the bottom.

## Frontmatter keys

| Key       | Type           | Purpose |
|-----------|----------------|---------|
| `id`      | string         | Stable identifier. Defaults to the file path. |
| `title`   | string         | Display name. Defaults to the first heading or the id. |
| `class`   | string         | Class. See [Record classes]({{< ref "record-classes" >}}). Defaults to `durable`. |
| `tags`    | list of string | Free-form. Used by the agent activation gate, by capability scoping, and by search filters. |
| `links`   | list of string | Outgoing links by id. Wikilinks parsed from the body are added at index time. |
| `created` | ISO-8601 date  | Optional creation date that you control. |
| `author`  | string         | Free-form. |

There is no `updated` key. Egghead reads `mtime` from the
filesystem and never writes it back, so an agent editing
frontmatter never has to worry about stomping a "last modified"
field.

## Wikilinks

<img class="decoration decoration--mercator" src="/assets/img/mercator-celestial-globe.png" alt="Mercator celestial globe — a wood-and-brass globe of the heavens" width="923" height="1152" decoding="async" loading="lazy">

A `[[target]]` token in a record body resolves to the record
whose `id` is `target`. If no record matches, the link renders
as an unresolved wikilink. That is a valid state, not an error;
it lets you write a link to a record you intend to create later.

The pipe form gives you a different display text:
`[[agents/scout|the research agent]]`.

At index time, wikilinks in the body are extracted and appended
to the record's `links` field, separately from any `links:` you
declared explicitly. Both are queryable.

## Indexing

Egghead keeps a SQLite index at `<records_dir>/.egghead/index.db`
with one row per record (class, tags, mtime, content size,
links) plus an FTS5 full-text table over title and body. The
index is derived state and is rebuilt on demand: deleting it and
restarting Egghead is safe, just slow on the first start.

A file watcher — FSEvents on macOS, `inotify` on Linux — picks
up external edits. If you change a record in `vim` or Obsidian
while Egghead is running, the change appears in search within a
few hundred milliseconds. You do not need to restart anything.

## Public API

The `Egghead` module is the supported entry point for `iex` and
for embedding Egghead into other code:

| Function | Purpose |
|----------|---------|
| `get_record/1` | Fetch by id. Returns `{:ok, record}` or `{:error, :not_found}`. |
| `list_records/0` | List every record in the store. |
| `search/2` | FTS5 query, with optional `class:` and `tags:` filters. |
| `find_links/2` | Outgoing links from a record. Pass `recursive: true` to traverse transitively. |
| `find_backlinks/1` | Records that link to this one. |
| `recent/1` | Recently updated records. |
| `create_record/1` | Validate, write, and index. |
| `update_record/2` | Update frontmatter or body. |

A short example:

```elixir
{:ok, results} = Egghead.search("postgres", class: "durable")
{:ok, record}  = Egghead.get_record("notes/postgres-vacuum")
backlinks      = Egghead.find_backlinks("notes/postgres-mvcc")
```

The same operations are available over MCP as `egghead_search`,
`egghead_get`, `egghead_list`, `egghead_find_links`,
`egghead_backlinks`, `egghead_recent`, `egghead_create`, and
`egghead_update`. See [MCP server]({{< ref "mcp" >}}).

## Editing records outside Egghead

Anything that reads Markdown reads your records: Obsidian,
`vim`, `cat`, `grep`, Git. Egghead's index will pick up changes
on the next file event.

Two practical consequences worth calling out. First, backups are
just `cp -r` or `rsync` against the records directory, with no
database to dump and no migrations to run. Second, version
control works exactly the way you would expect: `git init`
inside your records directory turns every note, every agent
definition, and every saved transcript into a diffable artifact
with history. Widening an agent's capabilities becomes a
reviewable Git change instead of a runtime side effect.
