defmodule Egghead.Tool.ProcExec do
  @moduledoc """
  Subprocess execution, argv-style, kernel-fenced via `Egghead.Sandbox`.

  The capability the agent holds is `proc.exec`, with `cmds:` / `patterns:`
  for argv-level allow-listing (enforced by `Egghead.Tool.Pattern` before
  spawn) and `in:` for the sandbox root (enforced by the kernel — sandbox-exec
  on macOS, bwrap on Linux — via `Egghead.Sandbox.spawn/3`).

  Arguments are passed as an argv list to `spawn_executable`; there is no
  `bash -c`, no shell interpretation, no injection surface. That is what
  makes this `proc.exec` and not `proc.eval`. Output is streamed to the
  subscriber per chunk and buffered for the tool_result.
  """

  alias Egghead.Capability.Request
  alias Egghead.Sandbox
  alias Egghead.Sandbox.Profile
  alias Egghead.Tool.Output
  alias Egghead.Tool.Pattern

  @default_timeout 30_000

  @doc """
  Builds the capability request this call would make. The scope includes
  the full argv so the matcher can apply cmds + patterns.
  """
  @spec request_for(map()) :: {:ok, [Request.t()]} | {:error, term()}
  def request_for(%{"cmd" => cmd} = input) do
    argv = build_argv(cmd, input["args"])

    {:ok,
     [
       %Request{
         resource: :proc,
         verb: :exec,
         scope: %{cmd: hd(argv), argv: argv},
         tool: "proc_exec"
       }
     ]}
  end

  def request_for(_), do: {:error, "proc_exec requires a cmd"}

  @doc """
  Runs the command. `opts` may include `:on_output` (a callback invoked
  per chunk for streaming), `:cwd` (working directory), and `:sandbox`
  (`%Egghead.Sandbox.Profile{}`; when provided, the subprocess is
  fenced in the kernel).

  Returns `{:ok, combined_output}` or `{:error, reason}`.
  """
  @spec run(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(input, opts \\ [])

  def run(%{"cmd" => cmd} = input, opts) do
    argv = build_argv(cmd, input["args"])
    _ = cmd
    timeout = input["timeout"] || @default_timeout
    cwd = opts[:cwd] || input["cwd"] || File.cwd!()
    on_output = opts[:on_output]
    profile = opts[:sandbox]

    case System.find_executable(hd(argv)) do
      nil ->
        {:error, "command not found: #{hd(argv)}"}

      executable ->
        run_port(executable, tl(argv), cwd, timeout, on_output, profile)
    end
  end

  def run(_, _opts), do: {:error, "proc_exec requires a cmd"}

  # --- impl ---

  defp build_argv(cmd, args) when is_binary(cmd) do
    extra = normalize_args(args)
    [cmd | extra]
  end

  defp build_argv(list, _) when is_list(list), do: Enum.map(list, &to_string/1)
  defp build_argv(cmd, args), do: [to_string(cmd) | normalize_args(args)]

  defp normalize_args(nil), do: []
  defp normalize_args(args) when is_list(args), do: Enum.map(args, &to_string/1)
  defp normalize_args(_), do: []

  defp run_port(executable, args, cwd, timeout, on_output, profile) do
    case spawn_port(executable, args, cwd, profile) do
      {:ok, port} -> collect(port, "", on_output, deadline(timeout))
      {:error, reason} -> {:error, reason}
    end
  end

  # If a profile is present we route through Sandbox.spawn so the
  # kernel-level fence is in force. Without a profile (an agent that
  # holds no external caps, or one running on an unsupported platform)
  # we fall back to an ordinary Port.open — same behavior as before
  # the sandbox layer existed.
  defp spawn_port(executable, args, cwd, %Profile{} = profile) do
    Sandbox.spawn(executable, args, sandbox: profile, cwd: cwd)
  end

  defp spawn_port(executable, args, cwd, nil) do
    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, :stderr_to_stdout, :hide, {:args, args}, {:cd, cwd}]
      )

    {:ok, port}
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp collect(port, buffer, on_output, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        kill(port)
        {:error, "timed out — command killed"}

      true ->
        receive do
          {^port, {:data, chunk}} ->
            if on_output, do: on_output.(chunk)
            {buffer, _status} = Output.append(buffer, chunk)
            collect(port, buffer, on_output, deadline)

          {^port, {:exit_status, 0}} ->
            Sandbox.cleanup(port)
            finalize(buffer)

          {^port, {:exit_status, code}} ->
            Sandbox.cleanup(port)
            {result, _status} = Output.append(buffer, "\n[exit #{code}]")
            finalize(result, exit: code)
        after
          remaining ->
            kill(port)
            {:error, "timed out — command killed"}
        end
    end
  end

  defp finalize(buffer, opts \\ []) do
    exit_code = Keyword.get(opts, :exit, 0)

    case Output.apply(buffer) do
      {:ok, text} when exit_code == 0 -> {:ok, ensure_trailing_nl(text)}
      {:ok, text} -> {:error, ensure_trailing_nl(text)}
      {:truncated, text, _} when exit_code == 0 -> {:ok, ensure_trailing_nl(text)}
      {:truncated, text, _} -> {:error, ensure_trailing_nl(text)}
      {:binary, notice} -> {:error, notice}
    end
  end

  defp ensure_trailing_nl(""), do: ""

  defp ensure_trailing_nl(text) do
    if String.ends_with?(text, "\n"), do: text, else: text <> "\n"
  end

  defp kill(port) do
    Sandbox.cleanup(port)

    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end

  # --- integration with Capability.Matcher for scope checking ---

  @doc """
  Checks a pre-built capability scope against the scope of a grant held
  by the agent. Called from the Matcher for the `proc.exec` resource —
  delegates to `Pattern.check/2` so the grant's `cmds:` and `patterns:`
  are consulted correctly.

  Returns `:ok` or `{:scope_violation, reason}`.
  """
  @spec check_against_grant(map(), map()) :: :ok | {:scope_violation, String.t()}
  def check_against_grant(grant_scope, request_scope) do
    argv = Map.get(request_scope, :argv, [to_string(Map.get(request_scope, :cmd, ""))])
    Pattern.check(argv, grant_scope)
  end
end
