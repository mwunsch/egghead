defmodule Egghead.SandboxTest do
  use ExUnit.Case, async: true

  alias Egghead.Sandbox
  alias Egghead.Sandbox.Profile

  @moduletag :sandbox

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "egghead-sandbox-test-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    %{workspace: workspace}
  end

  defp collect(port, buf \\ "") do
    receive do
      {^port, {:data, chunk}} -> collect(port, buf <> chunk)
      {^port, {:exit_status, code}} -> {code, buf}
    after
      5_000 ->
        try do
          Port.close(port)
        catch
          _, _ -> :ok
        end

        {:timeout, buf}
    end
  end

  describe "clamp_agent_sandbox/3 — widening rule" do
    import ExUnit.CaptureLog

    alias Egghead.Agent.Session

    test "passes through a narrower agent sandbox (subpath of config)" do
      assert Session.clamp_agent_sandbox("/tmp/ws/lib", "/tmp/ws", "agents/test") ==
               "/tmp/ws/lib"
    end

    test "passes through when agent sandbox equals config sandbox" do
      assert Session.clamp_agent_sandbox("/tmp/ws", "/tmp/ws", "agents/test") == "/tmp/ws"
    end

    test "clamps + warns when agent sandbox is outside config" do
      log =
        capture_log(fn ->
          assert Session.clamp_agent_sandbox("/etc", "/tmp/ws", "agents/escaper") ==
                   "/tmp/ws"
        end)

      assert log =~ "agents/escaper"
      assert log =~ "/etc"
      assert log =~ "/tmp/ws"
      assert log =~ "can only narrow"
    end

    test "clamps + warns on sibling escapes" do
      # /tmp/other is not a subpath of /tmp/ws even though they share /tmp
      log =
        capture_log(fn ->
          assert Session.clamp_agent_sandbox("/tmp/other", "/tmp/ws", "agents/x") ==
                   "/tmp/ws"
        end)

      assert log =~ "can only narrow"
    end

    test "nil agent sandbox stays nil regardless of config" do
      assert Session.clamp_agent_sandbox(nil, "/tmp/ws", "x") == nil
      assert Session.clamp_agent_sandbox(nil, nil, "x") == nil
    end

    test "agent sandbox passes through when no config ceiling" do
      assert Session.clamp_agent_sandbox("/anywhere", nil, "x") == "/anywhere"
    end
  end

  describe "Profile.validate/1" do
    test "rejects empty roots" do
      assert {:error, _} = Profile.validate(%Profile{})
    end

    test "rejects relative roots" do
      assert {:error, msg} = Profile.validate(%Profile{roots: ["relative/path"]})
      assert msg =~ "absolute"
    end

    test "accepts absolute root" do
      assert :ok = Profile.validate(%Profile{roots: ["/tmp"]})
    end
  end

  describe "spawn/3 on a supported platform" do
    @describetag :sandbox_platform

    test "positive: command inside workspace succeeds", %{workspace: ws} do
      profile = Profile.from_root(ws, net: false)
      out_file = Path.join(ws, "ok.txt")

      {:ok, port} =
        Sandbox.spawn("/bin/sh", ["-c", "echo hi > #{out_file} && cat #{out_file}"],
          sandbox: profile,
          cwd: ws
        )

      {code, buf} = collect(port)
      Sandbox.cleanup(port)

      assert code == 0, "exit #{code}, buf=#{inspect(buf)}"
      assert buf =~ "hi"
      assert File.read!(out_file) == "hi\n"
    end

    test "negative: write outside workspace is denied", %{workspace: ws} do
      profile = Profile.from_root(ws, net: false)

      escape =
        Path.join(
          System.tmp_dir!(),
          "egghead-sandbox-escape-#{:erlang.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm(escape) end)

      {:ok, port} =
        Sandbox.spawn("/bin/sh", ["-c", "echo pwned > #{escape} 2>&1; echo done"],
          sandbox: profile,
          cwd: ws
        )

      {_code, _buf} = collect(port)
      Sandbox.cleanup(port)

      refute File.exists?(escape),
             "sandbox did not contain the subprocess — #{escape} was written"
    end

    test "negative: /tmp writes are denied by default", %{workspace: ws} do
      # /tmp is a common convenience path but the sandbox should not
      # silently grant it — an agent confined to `ws` should not be
      # able to write outside `ws`, including /tmp.
      profile = Profile.from_root(ws, net: false)
      escape = "/tmp/egghead-sandbox-escape-#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> File.rm(escape) end)

      {:ok, port} =
        Sandbox.spawn("/bin/sh", ["-c", "echo pwned > #{escape} 2>&1; echo done"],
          sandbox: profile,
          cwd: ws
        )

      {_code, _buf} = collect(port)
      Sandbox.cleanup(port)

      refute File.exists?(escape),
             "sandbox allowed a /tmp escape — #{escape} was written"
    end

    test "TMPDIR redirect: env points into workspace scratch dir", %{workspace: ws} do
      # Tools that respect $TMPDIR (Python tempfile, git, most POSIX
      # libc tempfile() users) should write their scratch files into a
      # workspace-internal directory, not /tmp. This is how the sandbox
      # stays airtight without breaking tools that genuinely need scratch.
      # Note: macOS `mktemp(1)` is a BSD quirk that ignores $TMPDIR, so
      # we test the env variable itself rather than mktemp behavior.
      profile = Profile.from_root(ws, net: false)

      {:ok, port} =
        Sandbox.spawn(
          "/bin/sh",
          ["-c", ~s|echo "TMPDIR=$TMPDIR"|],
          sandbox: profile,
          cwd: ws
        )

      {code, buf} = collect(port)
      Sandbox.cleanup(port)

      assert code == 0, "subprocess failed: #{inspect(buf)}"
      assert buf =~ "TMPDIR=#{Path.join(ws, ".egghead-tmp")}"
      assert File.dir?(Path.join(ws, ".egghead-tmp"))
    end

    test "negative: read outside workspace is denied", %{workspace: ws} do
      # /etc/hosts is readable by default, but not under our sandbox.
      profile = Profile.from_root(ws, net: false)

      {:ok, port} =
        Sandbox.spawn("/bin/sh", ["-c", "cat /etc/hosts 2>&1 || echo BLOCKED"],
          sandbox: profile,
          cwd: ws
        )

      {_code, buf} = collect(port)
      Sandbox.cleanup(port)

      # Either the shell got "Operation not permitted" or our fallback "BLOCKED" marker.
      refute buf =~ "localhost",
             "sandbox leaked /etc/hosts contents: #{inspect(buf)}"
    end
  end
end
