defmodule Egghead.Record do
  @moduledoc """
  A knowledge record in the Egghead store.

  Records follow Zettelkasten conventions: atomic (one idea per record),
  linked (explicit cross-references via the `links` field), and attributed
  (author, timestamp, provenance).

  Three record classes exist with different lifecycle semantics:

  - `:durable` — long-lived knowledge records. Permanent until explicitly retired.
  - `:inbox` — ephemeral artifacts (email summaries, scraped pages). May expire.
  - `:deliberation` — audit trails of agent deliberation. Append-only.
  """

  @type class :: :durable | :inbox | :deliberation | :transcript | :agent | :skill

  @type wikilink :: %{
          target: String.t(),
          display: String.t() | nil,
          fragment: String.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t() | nil,
          created: String.t() | nil,
          updated: String.t() | nil,
          author: String.t() | nil,
          tags: [String.t()],
          links: [String.t()],
          wikilinks: [wikilink()],
          class: class(),
          meta: %{String.t() => term()},
          body: String.t(),
          ast: list() | nil,
          outline: [%{level: non_neg_integer(), text: String.t()}],
          format: :markdown | :org,
          source_path: String.t() | nil
        }

  # `updated` is strictly filesystem-owned and is stripped from
  # frontmatter on read (never surfaced on `meta`). `created` is
  # authorable-with-fallback: if it was authored in frontmatter we
  # want it to survive in `meta` so the writer knows to preserve it.
  # Filesystem-derived `created` values are kept out of `meta` and
  # therefore don't get written back to yaml.
  @known_keys ~w(id title updated author tags links class)

  @doc """
  Returns the list of known/reserved frontmatter keys.
  """
  @spec known_keys() :: [String.t()]
  def known_keys, do: @known_keys

  @enforce_keys [:id]
  defstruct [
    :id,
    :title,
    :created,
    :updated,
    :author,
    tags: [],
    links: [],
    wikilinks: [],
    class: :durable,
    meta: %{},
    body: "",
    ast: nil,
    outline: [],
    format: :markdown,
    source_path: nil
  ]

  @valid_classes ~w(durable inbox deliberation transcript agent skill)a

  @doc """
  Returns the list of valid record classes.
  """
  @spec valid_classes() :: [class()]
  def valid_classes, do: @valid_classes

  @doc """
  Returns the union of authored `links` and body-derived `wikilinks`
  targets as a deduped list of record ids. Use this for graph
  traversal when callers want a combined view — `links` and
  `wikilinks` are stored separately so demonstrative wikilinks in
  prose don't leak into authored metadata.
  """
  @spec references(t()) :: [String.t()]
  def references(%__MODULE__{links: links, wikilinks: wikilinks}) do
    Enum.uniq(links ++ Enum.map(wikilinks || [], & &1.target))
  end

  @doc """
  Parses a class string into an atom. Returns `:durable` for unrecognized values.
  """
  @spec parse_class(String.t() | atom() | nil) :: class()
  def parse_class(nil), do: :durable
  def parse_class(val) when is_atom(val) and val in @valid_classes, do: val

  def parse_class(val) when is_binary(val) do
    atom = String.to_atom(val)
    if atom in @valid_classes, do: atom, else: :durable
  end

  def parse_class(_), do: :durable
end
