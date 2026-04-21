defmodule Egghead.TUI.SelectListTest do
  use ExUnit.Case, async: true

  alias Egghead.TUI.SelectList

  defp items do
    [
      %{id: "alpha", label: "Alpha"},
      %{id: "beta", label: "Beta"},
      %{id: "gamma", label: "Gamma"}
    ]
  end

  defp type(list, chars) do
    Enum.reduce(chars, list, fn c, l ->
      {l2, _} = SelectList.handle_key({:char, c}, l)
      l2
    end)
  end

  describe "new/2" do
    test "defaults the cursor to 0 when no marker or cursor_id is given" do
      list = SelectList.new(items())
      assert list.cursor == 0
      assert list.marker_id == nil
      assert list.filtered == items()
    end

    test "marker_id seeds the cursor to the marked row" do
      list = SelectList.new(items(), marker_id: "beta")
      assert list.cursor == 1
      assert list.marker_id == "beta"
    end

    test "cursor_id overrides marker_id for initial focus" do
      list = SelectList.new(items(), marker_id: "alpha", cursor_id: "gamma")
      assert list.cursor == 2
      assert list.marker_id == "alpha"
    end

    test "unknown cursor_id falls back to 0" do
      list = SelectList.new(items(), cursor_id: "does-not-exist")
      assert list.cursor == 0
    end
  end

  describe "handle_key/2 navigation" do
    test "down moves the cursor forward and emits cursor_moved" do
      list = SelectList.new(items())
      {list, status} = SelectList.handle_key({:key, :down}, list)

      assert list.cursor == 1
      assert status == {:cursor_moved, %{id: "beta", label: "Beta"}}
    end

    test "up from cursor 0 stays at 0" do
      list = SelectList.new(items())
      {list, status} = SelectList.handle_key({:key, :up}, list)

      assert list.cursor == 0
      # Current item re-emits — that's fine; the caller can idempotently
      # re-install the previewed item.
      assert status == {:cursor_moved, %{id: "alpha", label: "Alpha"}}
    end

    test "down past the last row clamps" do
      list = SelectList.new(items())

      list =
        Enum.reduce(1..10, list, fn _, l ->
          {l2, _} = SelectList.handle_key({:key, :down}, l)
          l2
        end)

      assert list.cursor == 2
    end

    test "ctrl_n / ctrl_p are aliases for down / up" do
      list = SelectList.new(items())
      {list, _} = SelectList.handle_key({:key, :ctrl_n}, list)
      {list, _} = SelectList.handle_key({:key, :ctrl_n}, list)
      assert list.cursor == 2

      {list, _} = SelectList.handle_key({:key, :ctrl_p}, list)
      assert list.cursor == 1
    end
  end

  describe "handle_key/2 commit + cancel" do
    test "escape cancels" do
      list = SelectList.new(items())
      {^list, status} = SelectList.handle_key({:key, :escape}, list)
      assert status == :cancelled
    end

    test "ctrl_g cancels (Emacs keyboard-quit)" do
      list = SelectList.new(items())
      {^list, status} = SelectList.handle_key({:key, :ctrl_g}, list)
      assert status == :cancelled
    end

    test "enter commits the focused item" do
      list = SelectList.new(items())
      {list, _} = SelectList.handle_key({:key, :down}, list)
      {_list, status} = SelectList.handle_key({:key, :enter}, list)

      assert status == {:committed, %{id: "beta", label: "Beta"}}
    end

    test "enter on an empty filtered list cancels" do
      list = SelectList.new(items()) |> type(~w(x y z))
      assert list.filtered == []

      {_list, status} = SelectList.handle_key({:key, :enter}, list)
      assert status == :cancelled
    end
  end

  describe "filter-as-you-type" do
    test "typing narrows filtered items case-insensitively" do
      list = SelectList.new(items()) |> type(["B"])
      assert Enum.map(list.filtered, & &1.id) == ["beta"]
      assert list.cursor == 0
    end

    test "filter matches the id too, not just the label" do
      list = SelectList.new([%{id: "agents/scout", label: "Scout"}]) |> type(~w(a g e n t))
      assert Enum.map(list.filtered, & &1.id) == ["agents/scout"]
    end

    test "backspace shortens the query and re-filters" do
      list = SelectList.new(items()) |> type(~w(B e))
      assert list.query == "Be"

      {list, _} = SelectList.handle_key({:key, :backspace}, list)
      assert list.query == "B"
      assert Enum.map(list.filtered, & &1.id) == ["beta"]
    end

    test "backspace at empty query is a no-op" do
      list = SelectList.new(items())
      {list, _} = SelectList.handle_key({:key, :backspace}, list)
      assert list.query == ""
    end

    test "empty query restores the full list" do
      list = SelectList.new(items()) |> type(~w(B))
      {list, _} = SelectList.handle_key({:key, :backspace}, list)
      assert Enum.map(list.filtered, & &1.id) == ["alpha", "beta", "gamma"]
    end
  end

  describe "freeform_prefix" do
    test "synthesizes a create row when the query doesn't match an existing id" do
      list =
        SelectList.new(items(), freeform_prefix: "+ create: ")
        |> type(~w(n e w))

      assert [
               %{id: "new", label: "+ create: new"}
               | _
             ] = list.filtered
    end

    test "no synthetic row when the query exactly matches an existing id" do
      list =
        SelectList.new(items(), freeform_prefix: "+ create: ")
        |> type(~w(b e t a))

      assert Enum.map(list.filtered, & &1.id) == ["beta"]
    end

    test "committing the synthetic row returns the raw query as the id" do
      list =
        SelectList.new([], freeform_prefix: "+ create: ")
        |> type(~w(f r e s h))

      {_list, status} = SelectList.handle_key({:key, :enter}, list)
      assert status == {:committed, %{id: "fresh", label: "+ create: fresh"}}
    end

    test "no prefix = no synthesis, even with zero matches" do
      list = SelectList.new([]) |> type(~w(x))
      assert list.filtered == []
    end
  end

  describe "height/1" do
    test "one row per item plus a header, capped at 9 total" do
      # 8 items + 1 header
      big = for i <- 1..12, do: %{id: "i#{i}", label: "Item #{i}"}
      list = SelectList.new(big)
      assert SelectList.height(list) == 9
    end

    test "minimum 2 rows when filtered is empty" do
      list = SelectList.new(items()) |> type(~w(z))
      assert SelectList.height(list) == 2
    end
  end

  describe "view/2" do
    test "returns a view tree node sized to the picker height" do
      list = SelectList.new(items())

      assert {:vbox, %{width: 40, height: h}, _children} = SelectList.view(list, 40)
      assert h == SelectList.height(list)
    end
  end
end
