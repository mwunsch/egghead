defmodule Egghead.Record.Transcript do
  @moduledoc """
  Projection of a `:transcript`-class record into a typed view of a
  saved chat transcript. Mirrors the shape of `Egghead.Record.Agent`.

  Transcripts are produced by `Egghead.Chat.Room.save_transcript/1`
  and can be rehydrated into a live room via `to_room/1` — the Elixir
  equivalent of typing `/join <transcript-id>` in the TUI or web UI.

  Always succeeds; fills defaults for any absent meta key.
  """

  alias Egghead.Chat.Room
  alias Egghead.Chat.TranscriptParser
  alias Egghead.Record

  @type t :: %__MODULE__{
          record_id: String.t(),
          room_id: String.t(),
          title: String.t() | nil,
          participating_agents: [String.t()],
          body: String.t()
        }

  defstruct [
    :record_id,
    :room_id,
    :title,
    body: "",
    participating_agents: []
  ]

  @doc "Project a transcript record into typed config."
  @spec from(Record.t()) :: t()
  def from(%Record{} = record) do
    %__MODULE__{
      record_id: record.id,
      room_id: derive_room_id(record.id),
      title: record.title,
      body: record.body || "",
      participating_agents: record.links || []
    }
  end

  @doc """
  Parse the transcript body into structured messages. Delegates to
  `Egghead.Chat.TranscriptParser`.
  """
  @spec messages(t() | Record.t()) :: {:ok, [map()]} | {:error, term()}
  def messages(%__MODULE__{body: body, room_id: room_id}) do
    TranscriptParser.parse(body, room_id)
  end

  def messages(%Record{} = record), do: record |> from() |> messages()

  @doc """
  Rehydrate this transcript into a live chat room. Wraps
  `Egghead.Chat.Room.from_transcript/1`. Returns `{:ok, room_id}` on
  success, or `{:error, :not_found | :wrong_class | :parse_failed}`
  on failure.
  """
  @spec to_room(t() | Record.t()) :: {:ok, String.t()} | {:error, term()}
  def to_room(%__MODULE__{record_id: id}), do: Room.from_transcript(id)
  def to_room(%Record{} = record), do: Room.from_transcript(record.id)

  # Transcript records carry ids like `chat/<room-id>`. The room id
  # is what `Chat.Room` uses internally.
  defp derive_room_id("chat/" <> rest), do: rest
  defp derive_room_id(other), do: other
end
