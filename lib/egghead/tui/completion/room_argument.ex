defmodule Egghead.TUI.Completion.RoomArgument do
  @moduledoc """
  Room completion for `/join <prefix>`. Triggers once the input
  reads `/join ` (trailing space) or `/join <anything>`, ranks
  open rooms by prefix, and accepts by filling the input with
  `/join <chosen-room>`. Enter then dispatches the command
  through the normal `/join` path.

  The completion is pure filtering — it doesn't submit on
  select. That leaves room for the user to edit the filled
  argument, or to type a brand-new room name that no existing
  room matches (`/join staff-standup` creates that room on
  Enter via `Egghead.TUI.Chat.Update.resolve_join_target/1`).
  No synthetic "create" row is needed — typing the name IS
  the create path.
  """

  @behaviour Egghead.TUI.Completion.Provider

  alias Egghead.OpenTUI.EditBuffer
  alias Egghead.TUI.Completion

  @prefix "/join "

  @impl true
  def title, do: "room"

  @impl true
  def detect(%EditBuffer{} = buffer, model) do
    text = EditBuffer.to_text(buffer)

    with true <- String.starts_with?(String.downcase(text), @prefix),
         false <- String.contains?(text, "\n"),
         partial <- String.slice(text, String.length(@prefix)..-1//1) do
      current = Map.get(model, :room_id)
      rooms = rooms_for(current, partial)

      %Completion{
        provider: __MODULE__,
        prefix: partial,
        start_col: String.length(@prefix),
        end_col: String.length(text),
        candidates: rooms,
        selected: 0
      }
    else
      _ -> nil
    end
  end

  @impl true
  def label(%{id: id}), do: id

  @impl true
  def accept(_buffer, _completion, %{id: id}) do
    {:edit, EditBuffer.from_text(@prefix <> id)}
  end

  @impl true
  def ghost_suffix(%Completion{prefix: prefix} = completion) do
    case Completion.focused(completion) do
      %{id: id} ->
        if String.starts_with?(id, prefix),
          do: String.slice(id, String.length(prefix)..-1//1),
          else: ""

      _ ->
        ""
    end
  end

  # ---- Internals ----------------------------------------------------------

  defp rooms_for(current, partial) do
    needle = String.downcase(partial)

    all_rooms()
    |> Enum.reject(&(&1 == current))
    |> Enum.filter(&String.starts_with?(String.downcase(&1), needle))
    |> Enum.map(&%{id: &1})
  end

  defp all_rooms do
    try do
      Egghead.list_rooms()
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end
end
