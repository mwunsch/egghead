defmodule Egghead.ConfigIRCTest do
  @moduledoc """
  Locks in the always-on-with-defaults posture for the `irc:` config
  block. Mirrors how `web:` works: zero config produces a complete,
  bootable map; the block in YAML overrides individual fields.
  """

  use ExUnit.Case, async: false

  alias Egghead.Config

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "config.yml")
    previous = System.get_env("EGGHEAD_CONFIG")
    System.put_env("EGGHEAD_CONFIG", path)

    on_exit(fn ->
      if previous,
        do: System.put_env("EGGHEAD_CONFIG", previous),
        else: System.delete_env("EGGHEAD_CONFIG")
    end)

    {:ok, path: path}
  end

  describe "defaults" do
    test "default struct has a populated irc map" do
      assert %Config{irc: irc} = %Config{}
      assert irc.port == 6667
      assert irc.bind == "127.0.0.1"
      assert irc.hostname == nil
      assert irc.password == nil
    end

    test "yaml without an irc block yields the default irc map", %{path: path} do
      File.write!(path, "records_dir: ~/.egghead\n")

      assert {:ok, %Config{irc: irc}} = Config.load()
      assert irc.port == 6667
      assert irc.bind == "127.0.0.1"
      assert irc.hostname == nil
      assert irc.password == nil
    end
  end

  describe "yaml parsing" do
    test "parses port and bind", %{path: path} do
      File.write!(path, """
      irc:
        port: 6697
        bind: 0.0.0.0
      """)

      assert {:ok, %Config{irc: irc}} = Config.load()
      assert irc.port == 6697
      assert irc.bind == "0.0.0.0"
    end

    test "parses hostname and password", %{path: path} do
      File.write!(path, """
      irc:
        hostname: chat.example.com
        password: hunter2
      """)

      assert {:ok, %Config{irc: irc}} = Config.load()
      assert irc.hostname == "chat.example.com"
      assert irc.password == "hunter2"
      # Defaults preserved for fields not in YAML.
      assert irc.port == 6667
      assert irc.bind == "127.0.0.1"
    end

    test "resolves {env:VAR} in password", %{path: path} do
      System.put_env("EGGHEAD_TEST_IRC_PW", "from-env")
      on_exit(fn -> System.delete_env("EGGHEAD_TEST_IRC_PW") end)

      File.write!(path, """
      irc:
        password: "{env:EGGHEAD_TEST_IRC_PW}"
      """)

      assert {:ok, %Config{irc: irc}} = Config.load()
      assert irc.password == "from-env"
    end
  end

  describe "yaml round-trip" do
    test "saving + reloading preserves non-default irc fields", %{path: _path} do
      original = %Config{
        irc: %{port: 6697, bind: "0.0.0.0", hostname: "irc.example", password: "secret"}
      }

      :ok = Config.save(original)

      assert {:ok, %Config{irc: irc}} = Config.load()
      assert irc.port == 6697
      assert irc.bind == "0.0.0.0"
      assert irc.hostname == "irc.example"
      assert irc.password == "secret"
    end

    test "default irc block is omitted from emitted yaml", %{path: path} do
      :ok = Config.save(%Config{})

      content = File.read!(path)
      refute content =~ "irc:"
    end
  end
end
