defmodule Egghead.TUI.MarkdownCacheTest do
  use ExUnit.Case, async: false

  alias Egghead.OpenTUI.Markdown
  alias Egghead.TUI.MarkdownCache
  alias Egghead.TUI.OrgRender

  setup do
    case GenServer.whereis(MarkdownCache) do
      nil -> MarkdownCache.start_link([])
      _ -> :ok
    end

    MarkdownCache.reset()
    :ok
  end

  test "returns identical output to Markdown.render on miss and hit" do
    text = "A paragraph with **bold**, `code`, and a [[wikilink]]."
    direct = Markdown.render(text, 60)

    miss = MarkdownCache.render(text, 60)
    hit = MarkdownCache.render(text, 60)

    assert miss == direct
    assert hit == direct
    assert MarkdownCache.size() == 1
  end

  test "different widths are cached separately" do
    text = "some prose"
    _ = MarkdownCache.render(text, 40)
    _ = MarkdownCache.render(text, 60)

    assert MarkdownCache.size() == 2
  end

  test "different text is cached separately" do
    _ = MarkdownCache.render("one", 80)
    _ = MarkdownCache.render("two", 80)

    assert MarkdownCache.size() == 2
  end

  test "reset empties the cache" do
    _ = MarkdownCache.render("x", 80)
    assert MarkdownCache.size() == 1

    MarkdownCache.reset()
    assert MarkdownCache.size() == 0
  end

  test "render falls through when the cache table is absent" do
    # Stop the GenServer to drop the table, then call render.
    case GenServer.whereis(MarkdownCache) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    assert MarkdownCache.render("hello", 80) == Markdown.render("hello", 80)

    # Restore for the rest of the suite.
    {:ok, _} = MarkdownCache.start_link([])
  end

  test "format: :org routes to OrgRender" do
    text = "* TODO Stuff\n\nSome /italics/."

    cached = MarkdownCache.render(text, 80, format: :org)
    direct = OrgRender.render(text, 80)

    assert cached == direct
  end

  test "same text with different formats is cached separately" do
    text = "* heading"

    _ = MarkdownCache.render(text, 80, format: :markdown)
    _ = MarkdownCache.render(text, 80, format: :org)

    assert MarkdownCache.size() == 2
  end
end
