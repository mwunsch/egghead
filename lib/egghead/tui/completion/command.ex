defmodule Egghead.TUI.Completion.Command do
  @moduledoc """
  `/command` palette completion provider.

  Triggers whenever the buffer starts with `/` and doesn't
  contain a newline. The prefix is the text after `/`, up to
  the first space (so `/join staff` still triggers the command
  palette on `/join` — the `Egghead.TUI.Completion.RoomArgument`
  provider takes over once the space + partial room name
  appears).

  Accept replaces the input with `/<name> ` — filled, ready for
  the user to add an argument or press Enter to dispatch a
  zero-arg command.
  """

  @behaviour Egghead.TUI.Completion.Provider

  alias Egghead.OpenTUI.EditBuffer
  alias Egghead.TUI.Completion

  @impl true
  def title, do: "command"

  @impl true
  def detect(%EditBuffer{} = buffer, model) do
    text = EditBuffer.to_text(buffer)

    with true <- String.starts_with?(text, "/"),
         false <- String.contains?(text, "\n"),
         false <- String.contains?(text, " "),
         stripped <- String.trim_leading(text, "/"),
         commands <- command_list(model),
         candidates <- filter_commands(commands, stripped) do
      %Completion{
        provider: __MODULE__,
        prefix: stripped,
        start_col: 1,
        end_col: String.length(text),
        candidates: candidates,
        selected: 0,
        meta: %{}
      }
    else
      _ -> nil
    end
  end

  @impl true
  def label(%{name: name, description: desc}), do: "/#{name} — #{desc}"

  @impl true
  def accept(_buffer, _completion, %{name: name}) do
    # Always fill — the user presses Enter again with the
    # resulting buffer to dispatch (handled by the chat Update
    # module's main Enter handler).
    {:edit, EditBuffer.from_text("/#{name} ")}
  end

  @impl true
  def ghost_suffix(%Completion{prefix: prefix} = completion) do
    case Completion.focused(completion) do
      %{name: name} ->
        if String.starts_with?(name, prefix),
          do: String.slice(name, String.length(prefix)..-1//1),
          else: ""

      _ ->
        ""
    end
  end

  # ---- Internals ----------------------------------------------------------

  defp command_list(%{completion_commands: commands}) when is_list(commands), do: commands
  defp command_list(_), do: []

  defp filter_commands(commands, ""), do: commands

  defp filter_commands(commands, prefix) do
    needle = String.downcase(prefix)

    Enum.filter(commands, fn cmd ->
      cmd_lower = String.downcase(cmd.name)
      String.starts_with?(cmd_lower, needle)
    end)
  end
end
