defmodule Egghead.TUI.Completion.Agent do
  @moduledoc """
  `@`-mention completion provider. Detects `@prefix` under the
  cursor, ranks known agents (and the broadcast tokens
  `@everyone` / `@jam`) by prefix match on either full id or
  basename, and accepts by inserting an atomic mention token
  into the buffer.

  Delegates the existing pure logic — sigil walking and
  ranking — to `Egghead.TUI.Chat.Mentions`; this module is the
  plug that lets the shared `Completion` widget drive it.
  """

  @behaviour Egghead.TUI.Completion.Provider

  alias Egghead.OpenTUI.EditBuffer
  alias Egghead.TUI.Chat.Mentions
  alias Egghead.TUI.Chat.Mentions.Token
  alias Egghead.TUI.Completion

  @impl true
  def title, do: "agent"

  @impl true
  def detect(%EditBuffer{} = buffer, model) do
    case Mentions.detect(buffer) do
      %Mentions.Context{kind: :agent, prefix: prefix, start_col: sc, end_col: ec} ->
        candidates = Mentions.rank_agents(agents(model), prefix)

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
  def label(%{kind: :broadcast, id: id, label: label}), do: "#{id}  — #{label}"
  def label(%{id: id}), do: id
  def label(%{"id" => id}), do: id

  @impl true
  def hint(_), do: nil

  @impl true
  def accept(buffer, %Completion{prefix: prefix}, candidate) do
    id = agent_id(candidate)

    token = %Token{
      kind: :agent,
      id: id,
      display: "@#{id}",
      full_text: "@#{id}"
    }

    # Delete typed prefix + the `@` sigil (1 extra cell).
    buffer =
      buffer
      |> Completion.delete_n_before(String.length(prefix) + 1)
      |> EditBuffer.insert_cell(token)

    {:edit, buffer}
  end

  @impl true
  def ghost_suffix(%Completion{prefix: prefix} = completion) do
    candidate = Completion.focused(completion)

    if candidate == nil do
      ""
    else
      full = agent_id(candidate)
      basename = agent_basename(candidate)
      needle = String.downcase(prefix)

      cond do
        String.starts_with?(String.downcase(full), needle) ->
          String.slice(full, String.length(prefix)..-1//1)

        String.starts_with?(String.downcase(basename), needle) ->
          String.slice(basename, String.length(prefix)..-1//1)

        true ->
          ""
      end
    end
  end

  # ---- Internals ----------------------------------------------------------

  defp agents(%{agents: agents}) when is_list(agents), do: agents
  defp agents(_), do: []

  defp agent_id(%{id: id}), do: id
  defp agent_id(%{"id" => id}), do: id

  defp agent_basename(%{id: id}), do: id |> String.split("/") |> List.last()
  defp agent_basename(%{"id" => id}), do: id |> String.split("/") |> List.last()
end
