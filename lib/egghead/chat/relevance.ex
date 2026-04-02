defmodule Egghead.Chat.Relevance do
  @moduledoc """
  TF-IDF relevance scoring for agent activation ordering.

  Builds a corpus from agent documents (tags + disposition text) and scores
  incoming messages against it. Used by the Coordinator to determine which
  agent goes first in staggered activation — not for filtering, just ordering.

  Pure functions, no process state. The corpus is built once at agent
  registration and stored in Coordinator state.
  """

  @stopwords MapSet.new(~w(
    the a an is are was were be been being
    you your yours i my me we our
    and or but not no nor
    to of in for with at by from on as
    that this it its they them their
    do does did doing done
    have has had having
    will would should could can may might
    if when where what which who whom how
    so then than too also just
    about after before between each
    all any both few more most other some such
    up out over under again further
  ))

  @doc """
  Build a TF-IDF corpus from a map of agents.

  Takes `%{agent_id => %{tags: [...], disposition: "..."}}` and returns
  `%{agent_id => %{term => tfidf_weight}}`.
  """
  @spec build_corpus(%{String.t() => map()}) :: %{String.t() => %{String.t() => float()}}
  def build_corpus(agents) when map_size(agents) == 0, do: %{}

  def build_corpus(agents) do
    # Build term frequency maps per agent
    tf_maps =
      agents
      |> Enum.map(fn {id, info} ->
        doc = build_document(info)
        terms = tokenize(doc)
        tf = term_frequencies(terms)
        {id, tf}
      end)
      |> Map.new()

    # Compute inverse document frequency across all agents
    n = map_size(agents)
    idf = inverse_document_frequencies(tf_maps, n)

    # Compute TF-IDF per agent per term
    tf_maps
    |> Enum.map(fn {id, tf} ->
      tfidf =
        tf
        |> Enum.map(fn {term, freq} ->
          {term, freq * Map.get(idf, term, 0.0)}
        end)
        |> Map.new()

      {id, tfidf}
    end)
    |> Map.new()
  end

  @doc """
  Score a message against the corpus.

  Returns `%{agent_id => score}` where higher = more relevant.
  """
  @spec score(String.t(), %{String.t() => %{String.t() => float()}}) :: %{String.t() => float()}
  def score(_message, corpus) when map_size(corpus) == 0, do: %{}

  def score(message, corpus) do
    message_terms = message |> tokenize() |> MapSet.new()

    corpus
    |> Enum.map(fn {agent_id, tfidf} ->
      score =
        message_terms
        |> Enum.reduce(0.0, fn term, acc ->
          acc + Map.get(tfidf, term, 0.0)
        end)

      {agent_id, score}
    end)
    |> Map.new()
  end

  # --- Private ---

  defp build_document(info) do
    tags = (info.tags || info[:tags] || []) |> Enum.join(" ")
    disposition = info.disposition || info[:disposition] || ""
    "#{tags} #{disposition}"
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9\-]+/, trim: true)
    |> Enum.reject(&(&1 in @stopwords))
    |> Enum.reject(&(String.length(&1) < 2))
  end

  defp term_frequencies(terms) do
    total = length(terms)

    if total == 0 do
      %{}
    else
      terms
      |> Enum.frequencies()
      |> Enum.map(fn {term, count} -> {term, count / total} end)
      |> Map.new()
    end
  end

  defp inverse_document_frequencies(tf_maps, n) do
    # For each term, count how many agents' documents contain it
    tf_maps
    |> Map.values()
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.frequencies()
    |> Enum.map(fn {term, df} ->
      # Add 1 to avoid division by zero, standard smoothing
      {term, :math.log((n + 1) / (df + 1)) + 1}
    end)
    |> Map.new()
  end
end
