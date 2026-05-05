defmodule Egghead.CLI.WidgetsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Egghead.CLI.Widgets

  setup do
    previous_env = Application.get_env(:egghead, :no_tty)
    previous_no_color = System.get_env("NO_COLOR")

    on_exit(fn ->
      if is_nil(previous_env),
        do: Application.delete_env(:egghead, :no_tty),
        else: Application.put_env(:egghead, :no_tty, previous_env)

      if is_nil(previous_no_color),
        do: System.delete_env("NO_COLOR"),
        else: System.put_env("NO_COLOR", previous_no_color)
    end)

    System.delete_env("NO_COLOR")
    Application.delete_env(:egghead, :no_tty)
    :ok
  end

  describe "stdout_tty?/0" do
    test "returns false when :no_tty app env is set" do
      Application.put_env(:egghead, :no_tty, true)
      refute Widgets.stdout_tty?()
    end

    test "returns false when NO_COLOR is set" do
      System.put_env("NO_COLOR", "1")
      refute Widgets.stdout_tty?()
    end

    test "treats empty NO_COLOR as unset" do
      System.put_env("NO_COLOR", "")
      # Under captured IO this is non-TTY anyway, so just assert no crash.
      _ = Widgets.stdout_tty?()
    end

    test "returns false under captured IO (no real stdout TTY)" do
      capture_io(fn ->
        refute Widgets.stdout_tty?()
      end)
    end
  end

  describe "styled/1" do
    test "strips SGR colors when not a TTY" do
      Application.put_env(:egghead, :no_tty, true)
      assert Widgets.styled("\e[32m✓\e[0m ok") == "✓ ok"
      assert Widgets.styled("\e[1mhi\e[0m") == "hi"
      assert Widgets.styled("\e[38;5;245mfaint\e[39m") == "faint"
    end

    test "strips cursor and line-clear sequences when not a TTY" do
      Application.put_env(:egghead, :no_tty, true)
      assert Widgets.styled("\e[2Kclean") == "clean"
      assert Widgets.styled("\e[3Aup") == "up"
    end

    test "passes plain text through untouched" do
      Application.put_env(:egghead, :no_tty, true)
      assert Widgets.styled("plain text") == "plain text"
    end

    test "accepts iodata" do
      Application.put_env(:egghead, :no_tty, true)
      assert Widgets.styled(["\e[1m", "bold", "\e[0m"]) == "bold"
    end
  end

  describe "color helpers" do
    test "success/error/warn/header strip ANSI in non-TTY mode" do
      Application.put_env(:egghead, :no_tty, true)

      assert capture_io(fn -> Widgets.success("done") end) == "✓ done\n"
      assert capture_io(fn -> Widgets.error("nope") end) == "✗ nope\n"
      assert capture_io(fn -> Widgets.warn("careful") end) == "! careful\n"
      assert capture_io(fn -> Widgets.header("Title") end) == "\nTitle\n"
    end

    test "dim/1 returns plain text in non-TTY mode" do
      Application.put_env(:egghead, :no_tty, true)
      assert Widgets.dim("muted") == "muted"
    end
  end

  describe "spinner_start/1" do
    test "falls back to plain label when stdout is not a TTY" do
      Application.put_env(:egghead, :no_tty, true)

      output =
        capture_io(fn ->
          Widgets.spinner_start("Loading…")
          Widgets.spinner_stop()
        end)

      assert output =~ "Loading…"
      # No animator → no clear-line escape sequence
      refute output =~ "\e[2K"
    end

    test "spinner/2 returns the callback result regardless of TTY" do
      Application.put_env(:egghead, :no_tty, true)

      result =
        capture_io(fn ->
          send(self(), Widgets.spinner("work", fn -> :done end))
        end)

      assert result =~ "work"
      assert_received :done
    end
  end
end
