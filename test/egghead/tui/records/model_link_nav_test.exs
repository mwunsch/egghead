defmodule Egghead.TUI.Records.ModelLinkNavTest do
  use ExUnit.Case, async: true

  alias Egghead.TUI.Records.Model

  # Pure state-machine tests for link navigation. We construct
  # the model directly with a hand-built `preview_links` so the
  # tests don't depend on RecordStore or markdown rendering.
  defp model_with_links(targets) do
    links = Enum.map(targets, fn t -> %{target: t, kind: :forward} end)
    %Model{preview_links: links}
  end

  describe "link_mode?/1" do
    test "false by default" do
      refute Model.link_mode?(%Model{})
    end

    test "true after entering link mode" do
      m = model_with_links(["a", "b"]) |> Model.link_next()
      assert Model.link_mode?(m)
    end

    test "false after deselecting" do
      m =
        model_with_links(["a"])
        |> Model.link_next()
        |> Model.link_deselect()

      refute Model.link_mode?(m)
    end
  end

  describe "link_next/1" do
    test "no-op when there are no links" do
      m = Model.link_next(%Model{})
      assert m.link_index == nil
      refute Model.link_mode?(m)
    end

    test "selects first link from idle" do
      m = model_with_links(["a", "b", "c"]) |> Model.link_next()
      assert m.link_index == 0
      assert Model.active_link(m).target == "a"
    end

    test "advances to the next link" do
      m =
        model_with_links(["a", "b", "c"])
        |> Model.link_next()
        |> Model.link_next()

      assert m.link_index == 1
      assert Model.active_link(m).target == "b"
    end

    test "wraps from last back to first" do
      m =
        model_with_links(["a", "b"])
        |> Model.link_next()
        |> Model.link_next()
        |> Model.link_next()

      assert m.link_index == 0
      assert Model.active_link(m).target == "a"
    end
  end

  describe "link_prev/1" do
    test "no-op when there are no links" do
      m = Model.link_prev(%Model{})
      assert m.link_index == nil
    end

    test "selects last link from idle" do
      m = model_with_links(["a", "b", "c"]) |> Model.link_prev()
      assert m.link_index == 2
      assert Model.active_link(m).target == "c"
    end

    test "moves backward" do
      m =
        model_with_links(["a", "b", "c"])
        |> Model.link_next()
        |> Model.link_next()
        |> Model.link_prev()

      assert m.link_index == 0
      assert Model.active_link(m).target == "a"
    end

    test "wraps from first back to last" do
      m =
        model_with_links(["a", "b"])
        |> Model.link_next()
        |> Model.link_prev()

      assert m.link_index == 1
      assert Model.active_link(m).target == "b"
    end
  end

  describe "link_deselect/1" do
    test "is idempotent when not in link mode" do
      assert Model.link_deselect(%Model{}).link_index == nil
    end

    test "exits link mode but preserves the link list" do
      m =
        model_with_links(["a", "b"])
        |> Model.link_next()
        |> Model.link_deselect()

      assert m.link_index == nil
      assert length(m.preview_links) == 2
    end
  end

  describe "active_link/1" do
    test "nil when not in link mode" do
      assert Model.active_link(model_with_links(["a"])) == nil
    end

    test "returns the link entry at link_index" do
      m = model_with_links(["a", "b", "c"]) |> Model.link_next() |> Model.link_next()
      assert Model.active_link(m) == %{target: "b", kind: :forward}
    end
  end

  describe "nav_back/1" do
    test "is a no-op when nav_history is empty" do
      m = %Model{nav_history: []}
      assert Model.nav_back(m) == m
    end
  end
end
