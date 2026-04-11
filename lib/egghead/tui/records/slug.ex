defmodule Egghead.TUI.Records.Slug do
  @moduledoc """
  Convert a free-form title into a record id slug.

  Ported verbatim from `Egghead.TUI.App.slugify/1` on `main`
  (lines 1540–1549 of `lib/egghead/tui/app.ex`). The same edge
  cases are preserved:

    * Lowercase
    * Strip non-`(alnum/_/slash/dash)` characters → `-`
    * Collapse runs of `-`
    * Trim leading/trailing `-` per path segment
    * Drop empty segments
    * Slashes are preserved so titles like `"Agents / Scout"`
      produce nested ids like `"agents/scout"`

  Returns the empty string `""` if nothing usable remains.
  """

  @spec slugify(String.t()) :: String.t()
  def slugify(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r{[^a-z0-9_/-]+}, "-")
    |> String.replace(~r{-+}, "-")
    |> String.split("/")
    |> Enum.map(&String.trim(&1, "-"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("/")
  end
end
