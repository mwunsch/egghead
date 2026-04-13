defmodule Egghead.CLI.Prompts do
  @moduledoc """
  Interactive prompt helpers for CLI commands.

  Used by Mix tasks (init, llm, agent) and potentially by TUI
  slash commands or agents. Uses raw `IO` — no Mix.shell dependency.
  """

  @doc "Prompt with a default value. Returns trimmed input or default."
  @spec prompt(String.t(), String.t() | nil) :: String.t()
  def prompt(message, default \\ nil) do
    suffix = if default, do: " [#{default}]", else: ""

    case IO.gets("#{message}#{suffix}: ") do
      :eof -> default || ""
      result -> if String.trim(result) == "", do: default || "", else: String.trim(result)
    end
  end

  @doc "Prompt for a secret value (API key). Attempts to hide input."
  @spec secret(String.t()) :: String.t()
  def secret(message) do
    IO.write("#{message}: ")

    # Try Erlang's password input (no echo), fall back to regular IO
    result =
      try do
        case :io.get_password() do
          :eof -> ""
          chars when is_list(chars) -> List.to_string(chars) |> String.trim()
        end
      rescue
        _ -> IO.gets("") |> String.trim()
      catch
        _, _ -> IO.gets("") |> String.trim()
      end

    IO.puts("")
    result
  end

  @doc """
  Display a numbered list and return the chosen item.

  Options:
  - `:label` — function to extract display text from item (default: identity)
  """
  @spec select(String.t(), [term()], keyword()) :: term() | nil
  def select(message, items, opts \\ []) do
    label_fn = Keyword.get(opts, :label, &to_string/1)

    IO.puts(message)

    items
    |> Enum.with_index(1)
    |> Enum.each(fn {item, idx} ->
      IO.puts("  #{idx}) #{label_fn.(item)}")
    end)

    case IO.gets("> ") do
      :eof ->
        nil

      choice ->
        case Integer.parse(String.trim(choice)) do
          {n, ""} when n >= 1 and n <= length(items) ->
            Enum.at(items, n - 1)

          _ ->
            IO.puts("Invalid choice.")
            select(message, items, opts)
        end
    end
  end

  @doc """
  Display items grouped by category, return the chosen item.

  `groups` is a list of `{group_label, [items]}` tuples.
  """
  @spec select_grouped(String.t(), [{String.t(), [term()]}], keyword()) :: term() | nil
  def select_grouped(message, groups, opts \\ []) do
    label_fn = Keyword.get(opts, :label, &to_string/1)

    IO.puts(message)

    # Flatten with indices
    {flat, _} =
      Enum.reduce(groups, {[], 1}, fn {group_label, items}, {acc, idx} ->
        IO.puts("  #{group_label}")

        {new_acc, new_idx} =
          Enum.reduce(items, {acc, idx}, fn item, {a, i} ->
            IO.puts("    #{i}) #{label_fn.(item)}")
            {a ++ [{i, item}], i + 1}
          end)

        {new_acc, new_idx}
      end)

    case IO.gets("> ") do
      :eof ->
        nil

      choice ->
        case Integer.parse(String.trim(choice)) do
          {n, ""} ->
            case List.keyfind(flat, n, 0) do
              {_, item} ->
                item

              nil ->
                IO.puts("Invalid choice.")
                select_grouped(message, groups, opts)
            end

          _ ->
            IO.puts("Invalid choice.")
            select_grouped(message, groups, opts)
        end
    end
  end

  @doc "Yes/no confirmation. Returns boolean."
  @spec confirm(String.t(), boolean()) :: boolean()
  def confirm(message, default \\ true) do
    hint = if default, do: "[Y/n]", else: "[y/N]"

    case IO.gets("#{message} #{hint}: ") do
      :eof ->
        default

      result ->
        case String.trim(result) |> String.downcase() do
          "" -> default
          "y" -> true
          "yes" -> true
          "n" -> false
          "no" -> false
          _ -> confirm(message, default)
        end
    end
  end

  @doc """
  Multi-select with checkboxes. User enters comma-separated numbers to toggle.

  Returns list of selected items.
  """
  @spec checkboxes(String.t(), [{String.t(), term()}], keyword()) :: [term()]
  def checkboxes(message, items, opts \\ []) do
    defaults = Keyword.get(opts, :defaults, [])
    selected = MapSet.new(defaults)
    do_checkboxes(message, items, selected)
  end

  defp do_checkboxes(message, items, selected) do
    IO.puts(message)

    items
    |> Enum.with_index(1)
    |> Enum.each(fn {{label, value}, idx} ->
      check = if MapSet.member?(selected, value), do: "x", else: " "
      IO.puts("  #{idx}) [#{check}] #{label}")
    end)

    IO.puts("  Enter numbers to toggle, or press Enter to confirm.")

    input =
      case IO.gets("> ") do
        :eof -> ""
        s -> String.trim(s)
      end

    case input do
      "" ->
        # Confirm — return selected values in original order
        items
        |> Enum.map(fn {_label, value} -> value end)
        |> Enum.filter(&MapSet.member?(selected, &1))

      input ->
        toggles =
          input
          |> String.split(~r/[,\s]+/)
          |> Enum.flat_map(fn s ->
            case Integer.parse(s) do
              {n, ""} when n >= 1 and n <= length(items) -> [n]
              _ -> []
            end
          end)

        new_selected =
          Enum.reduce(toggles, selected, fn idx, acc ->
            {_label, value} = Enum.at(items, idx - 1)

            if MapSet.member?(acc, value),
              do: MapSet.delete(acc, value),
              else: MapSet.put(acc, value)
          end)

        do_checkboxes(message, items, new_selected)
    end
  end

  @doc "Print a success line with green checkmark."
  def success(message), do: IO.puts("#{IO.ANSI.green()}✓#{IO.ANSI.reset()} #{message}")

  @doc "Print an error line with red X."
  def error(message), do: IO.puts("#{IO.ANSI.red()}✗#{IO.ANSI.reset()} #{message}")

  @doc "Print a warning line with yellow marker."
  def warn(message), do: IO.puts("#{IO.ANSI.yellow()}!#{IO.ANSI.reset()} #{message}")

  @doc "Print a header/section label."
  def header(message), do: IO.puts("\n#{IO.ANSI.bright()}#{message}#{IO.ANSI.reset()}")
end
