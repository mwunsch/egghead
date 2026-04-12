defmodule Egghead.Web.RecordsLiveTest do
  use Egghead.Web.ConnCase, async: false

  @moduletag :records

  setup %{tmp_dir: tmp_dir} do
    # Write test records BEFORE starting the record store,
    # so the initial scan indexes them immediately.
    File.write!(Path.join(tmp_dir, "hello-world.md"), """
    ---
    title: Hello World
    tags: [greeting, test]
    ---

    This is a **test record** with a [[link-target]].
    """)

    File.write!(Path.join(tmp_dir, "link-target.md"), """
    ---
    title: Link Target
    tags: [test]
    ---

    This record is linked from [[hello-world]].
    """)

    File.write!(Path.join(tmp_dir, "design-doc.md"), """
    ---
    title: Design Document
    tags: [design]
    class: durable
    ---

    Architecture notes.
    """)

    start_record_store(tmp_dir)

    :ok
  end

  test "mounts and lists records", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, ".record-item")
  end

  test "search filters the list", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    html = view |> element("form") |> render_change(%{"query" => "hello"})

    assert html =~ "Hello World"
    refute html =~ "Design Document"
  end

  test "clicking a record shows preview", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view |> element(".record-item", "Hello World") |> render_click()

    html = render(view)
    assert html =~ "Hello World"
    assert html =~ "test record"
  end

  test "mounting with id param shows record", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/?id=hello-world")

    assert html =~ "Hello World"
    assert html =~ "test record"
  end

  test "wikilinks render with data attributes", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/?id=hello-world")

    assert html =~ "data-wikilink=\"link-target\""
    assert html =~ "wikilink"
  end

  test "wikilink click navigates via patch", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/?id=hello-world")

    view |> element("a[data-wikilink=\"link-target\"]") |> render_click()

    html = render(view)
    assert html =~ "Link Target"
    assert html =~ "linked from"
  end
end
