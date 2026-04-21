defmodule Egghead.TUI.Completion.Record do
  @moduledoc """
  `[[record]]` completion provider. Detects an unclosed `[[`
  under the cursor, ranks records by id prefix, and accepts by
  inserting a `[[id]]` token into the buffer.
  """

  @behaviour Egghead.TUI.Completion.Provider

  alias Egghead.OpenTUI.EditBuffer
  alias Egghead.TUI.Chat.Mentions
  alias Egghead.TUI.Chat.Mentions.Token
  alias Egghead.TUI.Completion

  @impl true
  def title, do: "record"

  @impl true
  def detect(%EditBuffer{} = buffer, model) do
    case Mentions.detect(buffer) do
      %Mentions.Context{kind: :record, prefix: prefix, start_col: sc, end_col: ec} ->
        candidates = Mentions.rank_records(records(model), prefix)

        %Completion{
          provider: __MODULE__,
          prefix: prefix,
          start_col: sc,
          end_col: ec,
          candidates: candidates,
          selected: 0
        }

      _ ->
        nil
    end
  end

  @impl true
  def label(%{id: id}), do: id
  def label(%{"id" => id}), do: id

  @impl true
  def hint(_), do: nil

  @impl true
  def accept(buffer, %Completion{prefix: prefix}, candidate) do
    id = record_id(candidate)

    token = %Token{
      kind: :record,
      id: id,
      display: "[[#{id}]]",
      full_text: "[[#{id}]]"
    }

    # Delete prefix + `[[` sigil (2 cells).
    buffer =
      buffer
      |> Completion.delete_n_before(String.length(prefix) + 2)
      |> EditBuffer.insert_cell(token)

    {:edit, buffer}
  end

  @impl true
  def ghost_suffix(%Completion{prefix: prefix} = completion) do
    candidate = Completion.focused(completion)

    if candidate == nil do
      ""
    else
      id = record_id(candidate)

      if String.starts_with?(String.downcase(id), String.downcase(prefix)),
        do: String.slice(id, String.length(prefix)..-1//1),
        else: ""
    end
  end

  # Records are fetched live from the store rather than pulled
  # from the model — consistent with the pre-refactor behavior.
  # Wrapped in a rescue so an unavailable record store (tests,
  # early boot) doesn't crash detection.
  defp records(_model) do
    try do
      Egghead.recent(limit: 100)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp record_id(%{id: id}), do: id
  defp record_id(%{"id" => id}), do: id
end
