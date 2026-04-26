defmodule Egghead.TUI.ThemePickerTest do
  use ExUnit.Case, async: false
  # async: false because Theme.set/commit mutate :persistent_term and
  # the Application env snapshot, which are global.

  alias Egghead.OpenTUI.Colors
  alias Egghead.Theme
  alias Egghead.TUI.ThemePicker

  setup do
    prior_config = Application.get_env(:egghead, :config)
    prior_active_tuple = :persistent_term.get({Egghead.OpenTUI.Theme, :active}, nil)
    prior_env = System.get_env("EGGHEAD_CONFIG")

    # Isolate to a temp config dir
    temp_dir = Path.join(System.tmp_dir!(), "egghead-theme-picker-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    System.put_env("EGGHEAD_CONFIG", temp_dir)

    # Force config reload from temp dir
    :egghead
    |> Application.get_env(:config)
    |> then(fn _ ->
      case Egghead.Config.load() do
        {:ok, config} -> Application.put_env(:egghead, :config, config)
        _ -> :ok
      end
    end)

    # Pin the starting committed theme to something deterministic.
    Theme.commit("dos")

    on_exit(fn ->
      if prior_config, do: Application.put_env(:egghead, :config, prior_config)

      if prior_active_tuple,
        do: :persistent_term.put({Egghead.OpenTUI.Theme, :active}, prior_active_tuple)

      case prior_env do
        nil -> System.delete_env("EGGHEAD_CONFIG")
        v -> System.put_env("EGGHEAD_CONFIG", v)
      end

      File.rm_rf!(temp_dir)
    end)

    :ok
  end

  describe "open/0" do
    test "captures the currently committed theme as `original`" do
      picker = ThemePicker.open()
      assert picker.original == "dos"
      assert picker.list.marker_id == "dos"
    end

    test "seeds the cursor on the committed row" do
      picker = ThemePicker.open()
      focused = Enum.at(picker.list.filtered, picker.list.cursor)
      assert focused.id == "dos"
    end
  end

  describe "live preview" do
    test "arrow keys install the focused theme via Theme.set without moving the committed marker" do
      picker = ThemePicker.open()
      dos_bg = Colors.bg()

      {picker, :open} = ThemePicker.handle_key({:key, :down}, picker)

      # Palette flipped to the newly-focused theme — bg binary should differ
      # from the DOS bg we captured above.
      refute Colors.bg() == dos_bg

      # But committed_name() stayed on DOS: Theme.set/1 does not touch
      # the config snapshot.
      assert Theme.committed_name() == "dos"
      assert picker.original == "dos"
    end
  end

  describe "commit on Enter" do
    test "persists the focused theme, updates committed_name, closes the picker" do
      picker = ThemePicker.open()
      # Move off the committed row so Enter commits something new.
      {picker, :open} = ThemePicker.handle_key({:key, :down}, picker)
      focused_id = Enum.at(picker.list.filtered, picker.list.cursor).id
      refute focused_id == "dos"

      {_picker, status} = ThemePicker.handle_key({:key, :enter}, picker)
      assert status == :committed
      assert Theme.committed_name() == focused_id
    end
  end

  describe "cancel on Escape / Ctrl+G" do
    for key <- [:escape, :ctrl_g] do
      test "#{key} reverts the live-previewed palette back to the original" do
        picker = ThemePicker.open()
        dos_bg = Colors.bg()

        # Preview something else.
        {picker, :open} = ThemePicker.handle_key({:key, :down}, picker)
        refute Colors.bg() == dos_bg

        {_picker, status} = ThemePicker.handle_key({:key, unquote(key)}, picker)
        assert status == :cancelled

        # Theme is back where we started; committed_name unchanged.
        assert Colors.bg() == dos_bg
        assert Theme.committed_name() == "dos"
      end
    end
  end

  describe "apply/1" do
    test "commits a theme by name and updates committed_name" do
      assert :ok = ThemePicker.apply("hot-dog-stand")
      assert Theme.committed_name() == "hot-dog-stand"
    end

    test "returns :not_found for unknown themes" do
      assert {:error, :not_found} = ThemePicker.apply("completely-made-up-theme")
      # committed_name must not have been touched
      assert Theme.committed_name() == "dos"
    end
  end
end
