defmodule Egghead.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    previous = Application.get_env(:egghead, :no_tty)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:egghead, :no_tty),
        else: Application.put_env(:egghead, :no_tty, previous)
    end)

    Application.delete_env(:egghead, :no_tty)
    :ok
  end

  describe "global --no-tty flag" do
    test "sets :egghead :no_tty app env before dispatch" do
      capture_io(fn -> Egghead.CLI.main(["--no-tty", "--version"]) end)
      assert Application.get_env(:egghead, :no_tty) == true
    end

    test "is absent when not passed" do
      capture_io(fn -> Egghead.CLI.main(["--version"]) end)
      assert Application.get_env(:egghead, :no_tty) in [nil, false]
    end

    test "does not interfere with --version output" do
      output = capture_io(fn -> Egghead.CLI.main(["--no-tty", "--version"]) end)
      assert output =~ "egghead "
    end
  end
end
