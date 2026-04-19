defmodule Egghead.Record.Deliberation do
  @moduledoc """
  Projection of a `:deliberation`-class record into a typed summary
  of an agent's prior reasoning. Mirrors the shape of
  `Egghead.Record.Agent`.

  Deliberations are produced during handoff (see
  `Egghead.Agent.Session`) and during explicit `save_insights`
  calls. They carry a distilled markdown summary plus pointers back
  to the agent and room that produced them. They're consumed
  ("loaded into" an agent session) as priming context when a fresh
  session starts in the same room with empty history — see
  `context_for_session/2` and `latest_for_room/1`.

  Always succeeds; fills defaults for any absent meta key.
  """

  alias Egghead.Record

  @default_preview_chars 500

  @type t :: %__MODULE__{
          record_id: String.t(),
          agent_id: String.t() | nil,
          room_id: String.t() | nil,
          referenced_records: [String.t()],
          body: String.t(),
          updated: String.t() | nil
        }

  defstruct [
    :record_id,
    :agent_id,
    :room_id,
    :body,
    :updated,
    referenced_records: []
  ]

  @doc "Project a deliberation record into typed config."
  @spec from(Record.t()) :: t()
  def from(%Record{} = record) do
    tags = record.tags || []

    %__MODULE__{
      record_id: record.id,
      agent_id: record.author || tag_value(tags, "agent"),
      room_id: tag_value(tags, "room"),
      referenced_records: Record.references(record),
      body: record.body || "",
      updated: record.updated
    }
  end

  @doc """
  Render this deliberation as a prior-context block suitable for
  injection into an agent's system prompt when spinning up a fresh
  session. Caps the body at `:max_chars` (default
  #{@default_preview_chars}).
  """
  @spec context_for_session(t() | Record.t(), keyword()) :: String.t()
  def context_for_session(deliberation_or_record, opts \\ [])

  def context_for_session(%__MODULE__{} = d, opts) do
    max_chars = Keyword.get(opts, :max_chars, @default_preview_chars)

    preview =
      if String.length(d.body) > max_chars do
        String.slice(d.body, 0, max_chars) <> "..."
      else
        d.body
      end

    "Prior context (from #{d.record_id}):\n#{preview}"
  end

  def context_for_session(%Record{} = record, opts),
    do: record |> from() |> context_for_session(opts)

  @doc """
  Find the most recent deliberation record tagged for the given
  room, returned as a projection. Returns `nil` if none exist.
  """
  @spec latest_for_room(String.t()) :: t() | nil
  def latest_for_room(room_id) do
    case Egghead.search_by_tag("room:#{room_id}") do
      [] ->
        nil

      records ->
        latest = Enum.max_by(records, & &1.updated)

        case Egghead.get_record(latest.id) do
          {:ok, full} -> from(full)
          _ -> nil
        end
    end
  end

  # Pull the value from a `prefix:value` tag — used for the
  # `agent:<id>` and `room:<id>` tag conventions that deliberation
  # records carry.
  defp tag_value(tags, prefix) do
    Enum.find_value(tags, fn tag ->
      case String.split(tag, ":", parts: 2) do
        [^prefix, value] -> value
        _ -> nil
      end
    end)
  end
end
