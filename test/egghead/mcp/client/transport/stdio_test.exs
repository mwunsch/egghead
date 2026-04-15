defmodule Egghead.MCP.Client.Transport.StdioTest do
  use ExUnit.Case, async: true

  alias Egghead.MCP.Client.Transport.Stdio

  @moduletag :tmp_dir

  @echo_script ~s"""
  #!/usr/bin/env bash
  # Minimal MCP-ish echo server: reads a line, replies with the same
  # id and a canned result.
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
    method=$(printf '%s' "$line" | sed -E 's/.*"method":"([^"]+)".*/\\1/')
    printf '{"jsonrpc":"2.0","id":%s,"result":{"echoed":"%s"}}\\n' "$id" "$method"
  done
  """

  setup %{tmp_dir: dir} do
    script = Path.join(dir, "echo.sh")
    File.write!(script, @echo_script)
    File.chmod!(script, 0o755)
    {:ok, script: script}
  end

  test "round-trips a JSON-RPC request", %{script: script} do
    {:ok, pid} =
      Stdio.start_link(%{
        name: "echo-test",
        command: "bash #{script}",
        owner: self()
      })

    envelope = %{jsonrpc: "2.0", id: 42, method: "initialize", params: %{}}
    :ok = Stdio.send_request(pid, envelope)

    assert_receive {:mcp_response, %{"id" => 42, "result" => %{"echoed" => "initialize"}}}, 2_000

    Stdio.close(pid)
  end

  test "honors shell-style quoted args", %{tmp_dir: dir} do
    # Write a script that echoes its argv as JSON-RPC so we can see
    # what tokenization produced.
    probe = Path.join(dir, "probe.sh")

    File.write!(probe, ~s"""
    #!/usr/bin/env bash
    # Joins argv with '|' and echoes as JSON.
    joined=$(printf '%s|' "$@" | sed 's/|$//')
    printf '{"jsonrpc":"2.0","id":1,"result":{"argv":"%s"}}\\n' "$joined"
    # Stay alive until stdin closes so the test can read the reply.
    cat > /dev/null
    """)

    File.chmod!(probe, 0o755)

    {:ok, pid} =
      Stdio.start_link(%{
        name: "probe",
        command: ~s(bash #{probe} --header "authorization: Bearer abc123" --count 2),
        owner: self()
      })

    # The probe immediately dumps argv as its first line.
    assert_receive {:mcp_response, %{"result" => %{"argv" => argv}}}, 2_000

    # Tokens preserved: the quoted header stays as one argv entry.
    assert argv =~ "authorization: Bearer abc123"
    # The unquoted args are split.
    assert argv =~ "--count"
    assert argv =~ "|2"

    Stdio.close(pid)
  end

  test "expands {env:VAR} in the command before tokenization", %{tmp_dir: dir} do
    System.put_env("EGGHEAD_TEST_TOKEN", "secret-xyz")
    on_exit(fn -> System.delete_env("EGGHEAD_TEST_TOKEN") end)

    probe = Path.join(dir, "probe_env.sh")

    File.write!(probe, ~s"""
    #!/usr/bin/env bash
    joined=$(printf '%s|' "$@" | sed 's/|$//')
    printf '{"jsonrpc":"2.0","id":1,"result":{"argv":"%s"}}\\n' "$joined"
    cat > /dev/null
    """)

    File.chmod!(probe, 0o755)

    {:ok, pid} =
      Stdio.start_link(%{
        name: "probe-env",
        command: ~s(bash #{probe} "Bearer {env:EGGHEAD_TEST_TOKEN}"),
        owner: self()
      })

    assert_receive {:mcp_response, %{"result" => %{"argv" => argv}}}, 2_000
    assert argv =~ "Bearer secret-xyz"

    Stdio.close(pid)
  end

  test "fails fast when command isn't on PATH" do
    Process.flag(:trap_exit, true)

    result =
      Stdio.start_link(%{
        name: "ghost",
        command: "nonexistent-binary-xyz",
        owner: self()
      })

    assert {:error, {:bad_command, {:not_found, "nonexistent-binary-xyz"}}} = result
  end

  test "sends :mcp_error with exit_status when the child process dies", %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)

    dying = Path.join(dir, "die.sh")
    File.write!(dying, "#!/usr/bin/env bash\nexit 7\n")
    File.chmod!(dying, 0o755)

    {:ok, pid} =
      Stdio.start_link(%{
        name: "dying",
        command: "bash #{dying}",
        owner: self()
      })

    assert_receive {:mcp_error, {:exit_status, 7}}, 2_000
    # GenServer stops itself after sending :mcp_error; give it a tick
    # to actually stop before the test process exits.
    Process.sleep(50)
    refute Process.alive?(pid)
  end
end
