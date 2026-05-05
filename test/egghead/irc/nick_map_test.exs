defmodule Egghead.IRC.NickMapTest do
  use ExUnit.Case, async: true

  doctest Egghead.IRC.NickMap

  alias Egghead.IRC.NickMap

  describe "id_to_nick/1" do
    test "strips namespace prefix" do
      assert NickMap.id_to_nick("agents/scout") == "scout"
      assert NickMap.id_to_nick("users/mark") == "mark"
    end

    test "no prefix passes through" do
      assert NickMap.id_to_nick("scout") == "scout"
    end

    test "replaces invalid characters with underscore" do
      assert NickMap.id_to_nick("agents/the.judge") == "the_judge"
      assert NickMap.id_to_nick("agents/foo bar") == "foo_bar"
    end

    test "prepends underscore if first char is invalid" do
      assert NickMap.id_to_nick("agents/3llen") == "_3llen"
    end

    test "truncates to 30 chars" do
      long = "agents/" <> String.duplicate("a", 60)
      result = NickMap.id_to_nick(long)
      assert String.length(result) == 30
    end

    test "empty basename becomes underscore" do
      assert NickMap.id_to_nick("agents/") == "_"
    end
  end

  describe "valid_nick?/1" do
    test "accepts plain alpha" do
      assert NickMap.valid_nick?("scout")
      assert NickMap.valid_nick?("Mark")
    end

    test "accepts special starting chars" do
      assert NickMap.valid_nick?("_bot")
      assert NickMap.valid_nick?("[hi]")
    end

    test "rejects digit-leading" do
      refute NickMap.valid_nick?("3llen")
    end

    test "rejects period" do
      refute NickMap.valid_nick?("a.b")
    end

    test "rejects empty" do
      refute NickMap.valid_nick?("")
    end

    test "rejects too long" do
      refute NickMap.valid_nick?(String.duplicate("a", 31))
    end

    test "non-binary is invalid" do
      refute NickMap.valid_nick?(:atom)
      refute NickMap.valid_nick?(nil)
    end
  end

  describe "channel/room mapping" do
    test "room_to_channel prefixes #" do
      assert NickMap.room_to_channel("general") == "#general"
    end

    test "channel_to_room strips channel prefix" do
      assert NickMap.channel_to_room("#general") == "general"
      assert NickMap.channel_to_room("&local") == "local"
    end

    test "non-channel returns nil" do
      assert NickMap.channel_to_room("nick") == nil
    end
  end
end
