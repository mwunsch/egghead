defmodule Egghead.TUI.Chat.ViewTest do
  use ExUnit.Case, async: false

  alias Egghead.OpenTUI.Markdown
  alias Egghead.TUI.Chat.{Entry, Model, View}
  alias Egghead.TUI.MarkdownCache

  setup do
    case GenServer.whereis(MarkdownCache) do
      nil -> MarkdownCache.start_link([])
      _ -> :ok
    end

    MarkdownCache.reset()
    :ok
  end

  defp model_with(entries) do
    %Model{
      room_id: "test",
      width: 100,
      height: 30,
      transcript: entries,
      providers?: true
    }
  end

  test "view renders without crashing on a small transcript" do
    entries = [
      Entry.user("alice", "Hello there!"),
      Entry.agent("agents/scout", "scout", "Hi **Alice**.")
    ]

    # Purely a crash smoke test — the view builds an OpenTUI tree, we
    # just need to know it returns *something* shaped like a tree.
    tree = View.render(model_with(entries))
    assert is_map(tree) or is_list(tree) or is_tuple(tree)
  end

  test "view renders a multi-entry agent run without crashing" do
    e1 = Entry.agent("agents/scout", "scout", "First paragraph of output.")
    e2 = Entry.agent("agents/scout", "scout", "Second paragraph arrives later.")

    tree = View.render(model_with([e1, e2]))
    assert is_map(tree) or is_list(tree) or is_tuple(tree)
  end

  test "per-entry render output matches a direct merged render of the same text" do
    # Lock in the invariant: rendering [p1, p2] with the new per-entry
    # approach produces the same *span rows* as rendering "p1\n\np2" in
    # one Earmark pass, for prose-only paragraphs.
    width = 60
    t1 = "First paragraph body with **bold**."
    t2 = "Second paragraph with a [[wikilink]] in it."

    merged =
      "#{t1}\n\n#{t2}"
      |> Markdown.render(width)
      |> drop_trailing_empty()

    stacked =
      [t1, t2]
      |> Enum.map(fn t -> t |> Markdown.render(width) |> drop_trailing_empty() end)
      |> Enum.intersperse([[]])
      |> Enum.concat()

    assert stacked == merged
  end

  defp drop_trailing_empty(rows) do
    rows
    |> Enum.reverse()
    |> Enum.drop_while(fn row -> row == [] end)
    |> Enum.reverse()
  end
end
