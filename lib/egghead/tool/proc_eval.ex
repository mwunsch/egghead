defmodule Egghead.Tool.ProcEval do
  @moduledoc """
  Shell-pipeline execution via `bash -c`, kernel-fenced by the sandbox.

  Unlike `Egghead.Tool.ProcExec` — which spawns a single binary with an
  argv list and no shell interpretation — `ProcEval` runs a free-form
  shell string: pipelines, redirects, subshells, globs, command
  substitution. That only becomes tenable because the kernel sandbox
  (`Egghead.Sandbox`) contains the whole subtree the shell may spawn.
  The Elixir matcher is not attempting to reason about shell strings;
  it just checks that the caller holds `proc.eval` with a resolvable
  `in:` scope, and the kernel handles the rest.

  Input shape:

      %{"cmd" => "find . -name '*.md' | xargs grep todo | wc -l"}

  Only `cmd` is recognized — no argv, no splitting, no quoting tricks.
  The string is passed verbatim to `/bin/bash -c`.

  The `in:` scope is the sandbox root this invocation runs inside.
  `proc.eval` does **not** accept `cmds:` / `patterns:` — those would
  be meaningless against a free-form shell string.
  """

  alias Egghead.Capability.Request
  alias Egghead.Sandbox
  alias Egghead.Sandbox.Profile
  alias Egghead.Tool.Output

  @default_timeout 30_000

  @doc """
  Builds the capability request this call would make. Scope carries the
  shell string so denial messages and transcript logging show what was
  attempted. The matcher ignores the string content (no pattern check) —
  the sandbox is the boundary.
  """
  @spec request_for(map()) :: {:ok, [Request.t()]} | {:error, term()}
  def request_for(%{"cmd" => cmd}) when is_binary(cmd) and cmd != "" do
    {:ok,
     [
       %Request{
         resource: :proc,
         verb: :eval,
         scope: %{cmd: cmd},
         tool: "proc_eval"
       }
     ]}
  end

  def request_for(_), do: {:error, "proc_eval requires a non-empty `cmd` string"}

  @doc """
  Runs the shell string under the sandbox profile passed in `opts`.

  Opts:

    * `:sandbox` — `%Egghead.Sandbox.Profile{}` (required in practice;
      without one the grant would have been denied upstream).
    * `:cwd` — working directory inside the sandbox root.
    * `:on_output` — streaming chunk callback.

  Returns `{:ok, output}` on exit 0, `{:error, output_or_reason}`
  otherwise.
  """
  @spec run(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(input, opts \\ [])

  def run(%{"cmd" => cmd}, opts) when is_binary(cmd) do
    timeout = opts[:timeout] || @default_timeout
    cwd = opts[:cwd] || File.cwd!()
    on_output = opts[:on_output]
    profile = opts[:sandbox]

    # Prefer the system shell — /bin/bash on macOS, /bin/sh everywhere —
    # over whatever PATH serves up. A Homebrew bash links against dylibs
    # under /opt/homebrew that aren't in the sandbox's read allow-list,
    # so PATH-resolved shells fail with "file system sandbox blocked".
    # System shells ship under /usr and /bin, both already readable.
    shell = pick_system_shell()

    run_port(shell, ["-c", cmd], cwd, timeout, on_output, profile)
  end

  def run(_, _opts), do: {:error, "proc_eval requires a `cmd` string"}

  defp pick_system_shell do
    cond do
      File.regular?("/bin/bash") -> "/bin/bash"
      File.regular?("/bin/sh") -> "/bin/sh"
      true -> System.find_executable("sh") || "/bin/sh"
    end
  end

  # --- impl (parallels ProcExec.run_port/6) ---

  defp run_port(executable, args, cwd, timeout, on_output, profile) do
    case spawn_port(executable, args, cwd, profile) do
      {:ok, port} -> collect(port, "", on_output, deadline(timeout))
      {:error, reason} -> {:error, reason}
    end
  end

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
end
