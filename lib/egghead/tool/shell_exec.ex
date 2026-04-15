defmodule Egghead.Tool.ShellExec do
  @moduledoc """
  Shell command execution with argv[0] + pattern gating.

  Capability enforcement lives in `Egghead.Tool.Pattern` — the scope
  check runs inside `request_for/1` and its result is compared by
  `Capability.check/3` before this module's `run/3` is invoked.

  Execution uses `Port.open` with `:stderr_to_stdout` so we can
  stream stdout chunks to the subscriber (TUI/web) as they arrive,
  and buffer the full output (truncated via `Egghead.Tool.Output`)
  for the tool_result sent back to the model.

  Commands are spawned directly via the port — no `bash -c`, no
  shell interpretation, no injection surface. Environment is
  inherited minus a few noisy variables; cwd is the records_dir of
  the running agent (configurable per-invocation).
  """

  alias Egghead.Capability.Request
  alias Egghead.Tool.Output
  alias Egghead.Tool.Pattern

  @default_timeout 30_000

  @doc """
  Builds the capability request this call would make. The scope
  includes the full argv so the matcher can apply cmds + patterns.
  """
  @spec request_for(map()) :: {:ok, [Request.t()]} | {:error, term()}
  def request_for(%{"cmd" => cmd} = input) do
    argv = build_argv(cmd, input["args"])

    {:ok,
     [
       %Request{
         resource: :shell,
         verb: :exec,
         scope: %{cmd: hd(argv), argv: argv},
         tool: "shell_exec"
       }
     ]}
  end

  def request_for(_), do: {:error, "shell_exec requires a cmd"}

  @doc """
  Runs the command. `ctx` may include `:on_output` (a callback
  invoked per-chunk for streaming) and `:cwd` (working directory).

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

    case System.find_executable(hd(argv)) do
      nil ->
        {:error, "command not found: #{hd(argv)}"}

      executable ->
        run_port(executable, tl(argv), cwd, timeout, on_output)
    end
  end

  def run(_, _opts), do: {:error, "shell_exec requires a cmd"}

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

  defp run_port(executable, args, cwd, timeout, on_output) do
    port =
      Port.open(
        {:spawn_executable, executable},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          {:args, args},
          {:cd, cwd}
        ]
      )

    collect(port, "", on_output, deadline(timeout))
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
            finalize(buffer)

          {^port, {:exit_status, code}} ->
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
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end

  # --- integration with Capability.Matcher for scope checking ---

  @doc """
  Checks a pre-built capability scope against the scope of a grant
  held by the agent. Called from the Matcher for the `shell.exec`
  resource — we delegate to `Pattern.check/2` here so the grant's
  `cmds:` and `patterns:` are consulted correctly.

  Returns `:ok` or `{:scope_violation, reason}`.
  """
  @spec check_against_grant(map(), map()) :: :ok | {:scope_violation, String.t()}
  def check_against_grant(grant_scope, request_scope) do
    argv = Map.get(request_scope, :argv, [to_string(Map.get(request_scope, :cmd, ""))])
    Pattern.check(argv, grant_scope)
  end
end
