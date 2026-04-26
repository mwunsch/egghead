defmodule Egghead.ThemeTest do
  use ExUnit.Case, async: false

  alias Egghead.OpenTUI.Colors
  alias Egghead.Theme

  setup do
    prior_config = Application.get_env(:egghead, :config)
    prior_tuple = :persistent_term.get({Egghead.OpenTUI.Theme, :active}, nil)
    prior_env = System.get_env("EGGHEAD_CONFIG")

    # Isolate to a temp config dir
    temp_dir = Path.join(System.tmp_dir!(), "egghead-theme-test-#{System.unique_integer([:positive])}")
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

    # Pin the starting theme deterministically.
    Theme.commit("dos")

    on_exit(fn ->
      if prior_config, do: Application.put_env(:egghead, :config, prior_config)
      if prior_tuple, do: :persistent_term.put({Egghead.OpenTUI.Theme, :active}, prior_tuple)

      case prior_env do
        nil -> System.delete_env("EGGHEAD_CONFIG")
        v -> System.put_env("EGGHEAD_CONFIG", v)
      end

      File.rm_rf!(temp_dir)
    end)

    :ok
  end

  describe "set/1 vs commit/1" do
    test "set/1 paints but does NOT update committed_name" do
      dos_bg = Colors.bg()

      assert :ok = Theme.set("hot-dog-stand")
      assert Theme.committed_name() == "dos"
      # bg flipped — that's what set/1 is for.
      refute Colors.bg() == dos_bg
    end

    test "commit/1 paints AND updates committed_name" do
      assert :ok = Theme.commit("hot-dog-stand")
      assert Theme.committed_name() == "hot-dog-stand"
    end

    test "set/1 returns :not_found for unknown themes" do
      assert {:error, :not_found} = Theme.set("i-do-not-exist")
    end
  end

  describe "list/0 and builtins/0" do
    test "ships with the documented built-ins in display order" do
      names = Theme.builtins() |> Enum.map(& &1.name)

      assert names == [
               "terminal-dark",
               "terminal-light",
               "scholastic",
               "dos",
               "hot-dog-stand",
               "catppuccin-mocha",
               "solarized-light",
               "gruvbox-dark"
             ]
    end

    test "list/0 returns the built-in catalogue when no user themes are present" do
      assert Enum.map(Theme.list(), & &1.name) == Enum.map(Theme.builtins(), & &1.name)
    end
  end

  describe "fetch/1" do
    test "finds a built-in by name" do
      assert {:ok, theme} = Theme.fetch("dos")
      assert theme.display_name == "DOS BIOS"
    end

    test "returns :not_found for unknown names" do
      assert {:error, :not_found} = Theme.fetch("unknown")
    end
  end

  describe "user themes from disk" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "egghead-theme-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      themes_dir = Path.join(dir, "themes")
      File.mkdir_p!(themes_dir)

      System.put_env("EGGHEAD_CONFIG", dir)

      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, themes_dir: themes_dir}
    end

    test "loads a well-formed JSON theme", %{themes_dir: dir} do
      File.write!(Path.join(dir, "mine.json"), """
      {
        "name": "mine",
        "display_name": "Mine",
        "mode": "dark",
        "palette": {
          "accent": "#ff5f87",
          "fg": "#e0e0e0"
        }
      }
      """)

      names = Theme.list() |> Enum.map(& &1.name)
      assert "mine" in names

      {:ok, theme} = Theme.fetch("mine")
      assert theme.display_name == "Mine"
      assert theme.mode == :dark

      # Overrides land in the palette, and missing slots inherit from the
      # mode-appropriate base (terminal-dark here). fg override is the
      # hex we supplied → 16-byte RGBA.
      assert byte_size(theme.palette.fg) == 16
      # accent is explicitly set too.
      assert byte_size(theme.palette.accent) == 16
      # A slot we didn't set falls back — still a 16-byte binary from the base.
      assert byte_size(theme.palette.syntax_heading) == 16
    end

    test "skips malformed JSON without crashing the loader", %{themes_dir: dir} do
      File.write!(Path.join(dir, "broken.json"), "{not valid json}")

      File.write!(Path.join(dir, "ok.json"), """
      {"name": "ok", "mode": "dark", "palette": {}}
      """)

      names = Theme.list() |> Enum.map(& &1.name)
      assert "ok" in names
      refute "broken" in names
    end

    test "rejects themes with a bad mode", %{themes_dir: dir} do
      File.write!(Path.join(dir, "wrong-mode.json"), """
      {"name": "wrong-mode", "mode": "taupe", "palette": {}}
      """)

      refute "wrong-mode" in Enum.map(Theme.list(), & &1.name)
    end

    test "user-theme name collision overrides the built-in", %{themes_dir: dir} do
      File.write!(Path.join(dir, "dos.json"), """
      {"name": "dos", "display_name": "My DOS", "mode": "dark", "palette": {}}
      """)

      {:ok, theme} = Theme.fetch("dos")
      assert theme.display_name == "My DOS"
    end
  end
end
