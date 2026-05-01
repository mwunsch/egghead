defmodule Egghead.IRC.Format do
  @moduledoc """
  Pure rendering helpers shared across the IRC layer:

  - `tool_input/1` — formats a tool-call's arg map as a TUI-style
    `key=value key=value` suffix, with values truncated to ~40 chars.
  - `context_bar/1` — Claude Code-style `▓▓▓░░░` progress bar.
  - `int/1` — three-digit comma grouping for token counts.

  No I/O, no state — moved out of `Connection` so the per-connection
  module isn't carrying string formatting it doesn't need to own.
  """

  @doc """
  Format a tool-call's input map as a leading-space `key=value`
  string, mirroring the TUI: `" path=foo.md mode=read"`. Empty input
  → empty string.
  """
  def tool_input(nil), do: ""
  def tool_input(input) when input == %{}, do: ""

  def tool_input(input) when is_map(input) do
    pairs =
      input
      |> Enum.map(fn {k, v} -> "#{k}=#{truncate_tool_value(v)}" end)
      |> Enum.join(" ")

    if pairs == "", do: "", else: " " <> pairs
  end

  def tool_input(_other), do: ""

  defp truncate_tool_value(v) when is_binary(v) do
    cleaned = v |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(cleaned) > 40, do: String.slice(cleaned, 0, 37) <> "...", else: cleaned
  end

  defp truncate_tool_value(v), do: v |> inspect() |> truncate_tool_value()

  @doc "16-cell context-window bar — `▓` filled, `░` empty."
  def context_bar(pct) do
    width = 16
    filled = round(pct / 100 * width)
    String.duplicate("▓", filled) <> String.duplicate("░", width - filled)
  end

  @doc "Comma-grouped integer for human-readable token counts."
  def int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
    |> String.reverse()
  end

  def int(_), do: "?"
end
