defmodule Egghead.IRC.ProtocolTest do
  use ExUnit.Case, async: true

  doctest Egghead.IRC.Protocol

  alias Egghead.IRC.Protocol
  alias Egghead.IRC.Protocol.Message

  describe "parse/1" do
    test "bare command with no params" do
      {:ok, m} = Protocol.parse("PING")
      assert m.command == "PING"
      assert m.params == []
      assert m.trailing == nil
      assert m.prefix == nil
      assert m.tags == %{}
    end

    test "command with leading params and trailing" do
      {:ok, m} = Protocol.parse("PRIVMSG #room :hello world")
      assert m.command == "PRIVMSG"
      assert m.params == ["#room"]
      assert m.trailing == "hello world"
      assert Protocol.Message.args(m) == ["#room", "hello world"]
    end

    test "command with prefix" do
      {:ok, m} = Protocol.parse(":scout!~bot@host PRIVMSG #room :hi")
      assert m.prefix == "scout!~bot@host"
      assert m.command == "PRIVMSG"
      assert m.params == ["#room"]
      assert m.trailing == "hi"
    end

    test "command with multiple non-trailing params" do
      {:ok, m} = Protocol.parse("USER bot 0 * :Bot Name")
      assert m.params == ["bot", "0", "*"]
      assert m.trailing == "Bot Name"
    end

    test "uppercases command" do
      {:ok, m} = Protocol.parse("privmsg #room :hi")
      assert m.command == "PRIVMSG"
    end

    test "preserves CRLF stripped lines" do
      {:ok, m} = Protocol.parse("NICK foo\r")
      assert m.command == "NICK"
      assert m.params == ["foo"]
      assert m.trailing == nil
    end

    test "IRCv3 message tags" do
      {:ok, m} = Protocol.parse("@time=2026-04-30;account=mark :u JOIN #room")
      assert m.tags == %{"time" => "2026-04-30", "account" => "mark"}
      assert m.prefix == "u"
      assert m.command == "JOIN"
    end

    test "tag without value" do
      {:ok, m} = Protocol.parse("@bot PING :s")
      assert m.tags == %{"bot" => true}
    end

    test "trailing param with leading colon preserved" do
      {:ok, m} = Protocol.parse("PRIVMSG #room ::wat")
      assert m.params == ["#room"]
      assert m.trailing == ":wat"
    end

    test "empty input" do
      assert {:error, :empty} = Protocol.parse("")
    end

    test "tags-only with no command" do
      assert {:error, :no_command} = Protocol.parse("@only=tags")
    end

    test "prefix-only with no command" do
      assert {:error, :no_command} = Protocol.parse(":only-prefix")
    end
  end

  describe "chunk/2" do
    test "splits multiple complete lines" do
      {msgs, rest} = Protocol.chunk("", "NICK a\r\nUSER b 0 * :B\r\n")
      assert length(msgs) == 2
      assert Enum.map(msgs, & &1.command) == ["NICK", "USER"]
      [_nick, user] = msgs
      assert user.params == ["b", "0", "*"]
      assert user.trailing == "B"
      assert rest == ""
    end

    test "buffers an incomplete trailing line" do
      {msgs, rest} = Protocol.chunk("", "NICK a\r\nPART")
      assert length(msgs) == 1
      assert rest == "PART"
    end

    test "joins prior buffer with new bytes" do
      {msgs1, rest1} = Protocol.chunk("", "PRIV")
      assert msgs1 == []
      assert rest1 == "PRIV"

      {msgs2, rest2} = Protocol.chunk(rest1, "MSG #r :hi\r\n")
      assert length(msgs2) == 1
      assert hd(msgs2).command == "PRIVMSG"
      assert hd(msgs2).params == ["#r"]
      assert hd(msgs2).trailing == "hi"
      assert rest2 == ""
    end

    test "skips empty lines from doubled CRLF" do
      {msgs, _} = Protocol.chunk("", "PING\r\n\r\nPONG\r\n")
      assert Enum.map(msgs, & &1.command) == ["PING", "PONG"]
    end
  end

  describe "encode/1" do
    test "encodes a simple JOIN with no trailing" do
      m = %Message{command: "JOIN", params: ["#room"]}
      assert Protocol.encode(m) == "JOIN #room\r\n"
    end

    test "encodes a numeric with prefix and trailing" do
      m = %Message{prefix: "irc.local", command: "001", params: ["mark"], trailing: "Welcome"}
      assert Protocol.encode(m) == ":irc.local 001 mark :Welcome\r\n"
    end

    test "trailing param with spaces" do
      m = %Message{command: "PRIVMSG", params: ["#room"], trailing: "hello world"}
      assert Protocol.encode(m) == "PRIVMSG #room :hello world\r\n"
    end

    test "empty trailing param" do
      m = %Message{command: "PART", params: ["#room"], trailing: ""}
      assert Protocol.encode(m) == "PART #room :\r\n"
    end

    test "trailing param starting with colon" do
      m = %Message{command: "PRIVMSG", params: ["#room"], trailing: ":wat"}
      assert Protocol.encode(m) == "PRIVMSG #room ::wat\r\n"
    end

    test "encodes IRCv3 tags" do
      m = %Message{tags: %{"time" => "2026"}, command: "PING", trailing: "s"}
      assert Protocol.encode(m) == "@time=2026 PING :s\r\n"
    end

    test "round-trip parse → encode → parse stable" do
      lines = [
        "PRIVMSG #room :hello world",
        ":scout!u@h JOIN #general",
        "USER bot 0 * :Bot Name",
        "@time=2026 :s 001 mark :Welcome"
      ]

      for line <- lines do
        {:ok, m1} = Protocol.parse(line)
        encoded = Protocol.encode(m1)
        assert String.ends_with?(encoded, "\r\n")
        {:ok, m2} = Protocol.parse(String.trim_trailing(encoded, "\r\n"))
        assert m1.command == m2.command
        assert m1.prefix == m2.prefix
        assert m1.params == m2.params
        assert m1.trailing == m2.trailing
        assert m1.tags == m2.tags
      end
    end
  end
end
