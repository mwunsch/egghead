defmodule Egghead.OpenTUI.LayoutTest do
  use ExUnit.Case, async: true

  alias Egghead.OpenTUI.Layout

  describe "arrange/2 — leaves" do
    import Egghead.OpenTUI.View

    test "single text leaf takes the whole viewport" do
      tree = text("hello")
      assert Layout.arrange(tree, {0, 0, 80, 24}) == [{tree, {0, 0, 80, 24}}]
    end

    test "single fill takes the whole viewport" do
      tree = fill()
      assert Layout.arrange(tree, {0, 0, 80, 24}) == [{tree, {0, 0, 80, 24}}]
    end

    test ":nothing produces no leaves" do
      assert Layout.arrange(:nothing, {0, 0, 80, 24}) == []
    end
  end

  describe "arrange/2 — vbox" do
    import Egghead.OpenTUI.View

    test "fixed-height children stack top-to-bottom" do
      tree =
        vbox([
          text("a", height: 1),
          text("b", height: 2),
          text("c", height: 3)
        ])

      assert Layout.arrange(tree, {0, 0, 10, 10}) == [
               {{:text, "a", %{height: 1}}, {0, 0, 10, 1}},
               {{:text, "b", %{height: 2}}, {0, 1, 10, 2}},
               {{:text, "c", %{height: 3}}, {0, 3, 10, 3}}
             ]
    end

    test "single flex child consumes the leftover" do
      tree =
        vbox([
          text("hdr", height: 1),
          fill(flex: 1),
          text("ftr", height: 1)
        ])

      [_, {fill_node, fill_rect}, _] = Layout.arrange(tree, {0, 0, 80, 24})
      assert fill_node == {:fill, %{flex: 1}}
      assert fill_rect == {0, 1, 80, 22}
    end

    test "multiple flex children split by weight" do
      tree =
        vbox([
          text("hdr", height: 1),
          fill(flex: 1),
          fill(flex: 2),
          text("ftr", height: 1)
        ])

      rects = Layout.arrange(tree, {0, 0, 80, 24})
      # leftover = 22, weights total 3, → 7 + 15 (remainder to last flex)
      assert rects |> Enum.map(fn {_node, {_, _, _, h}} -> h end) ==
               [1, 7, 15, 1]
    end
  end

  describe "arrange/2 — hbox" do
    import Egghead.OpenTUI.View

    test "fixed-width children stack left-to-right" do
      tree =
        hbox([
          text("aa", width: 5),
          text("bb", width: 10),
          text("cc", width: 5)
        ])

      assert Layout.arrange(tree, {0, 0, 20, 1}) == [
               {{:text, "aa", %{width: 5}}, {0, 0, 5, 1}},
               {{:text, "bb", %{width: 10}}, {5, 0, 10, 1}},
               {{:text, "cc", %{width: 5}}, {15, 0, 5, 1}}
             ]
    end

    test "flex child fills leftover width" do
      tree =
        hbox([
          text("L", width: 10),
          fill(flex: 1),
          text("R", width: 10)
        ])

      [_, {_fill, {x, y, w, h}}, _] = Layout.arrange(tree, {0, 0, 80, 5})
      assert {x, y, w, h} == {10, 0, 60, 5}
    end
  end

  describe "arrange/2 — nesting" do
    import Egghead.OpenTUI.View

    test "vbox containing an hbox containing texts" do
      tree =
        vbox([
          text("header", height: 1),
          hbox(
            [flex: 1],
            [
              text("left", width: 20),
              fill(flex: 1)
            ]
          ),
          text("footer", height: 1)
        ])

      leaves = Layout.arrange(tree, {0, 0, 80, 10})

      # 4 leaves: header, left, fill, footer
      assert length(leaves) == 4
      assert Enum.at(leaves, 0) == {{:text, "header", %{height: 1}}, {0, 0, 80, 1}}
      assert Enum.at(leaves, 1) == {{:text, "left", %{width: 20}}, {0, 1, 20, 8}}
      assert Enum.at(leaves, 2) == {{:fill, %{flex: 1}}, {20, 1, 60, 8}}
      assert Enum.at(leaves, 3) == {{:text, "footer", %{height: 1}}, {0, 9, 80, 1}}
    end

    test "overlay places children at the same rect, last on top" do
      tree =
        overlay([
          fill(),
          text("modal")
        ])

      leaves = Layout.arrange(tree, {0, 0, 40, 10})
      assert length(leaves) == 2
      # Both leaves at the same rect
      assert {_, {0, 0, 40, 10}} = Enum.at(leaves, 0)
      assert {_, {0, 0, 40, 10}} = Enum.at(leaves, 1)
      # The text comes second (drawn last → on top)
      assert match?({{:text, "modal", _}, _}, Enum.at(leaves, 1))
    end
  end
end
